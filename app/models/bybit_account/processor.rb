# frozen_string_literal: true

# Updates account balance and imports spot trade (execution) history.
class BybitAccount::Processor
  include BybitAccount::UsdConverter

  # Quote currencies probed when splitting a Bybit spot symbol (e.g. BTCUSDT → BTC).
  # Ordered by length so longer quotes match before shorter ones.
  QUOTE_CURRENCIES = %w[USDT USDC BUSD DAI BTC ETH EUR].freeze

  # Bybit /v5/execution/list only allows a 7-day window per request.
  MAX_WINDOW = 7.days
  # How far back to look on the very first sync when no start date is configured.
  DEFAULT_LOOKBACK = 30.days

  attr_reader :bybit_account

  def initialize(bybit_account)
    @bybit_account = bybit_account
  end

  def process
    unless bybit_account.current_account.present?
      Rails.logger.info "BybitAccount::Processor - no linked account for #{bybit_account.id}, skipping"
      return
    end

    begin
      BybitAccount::HoldingsProcessor.new(bybit_account).process
    rescue StandardError => e
      Rails.logger.error "BybitAccount::Processor - holdings failed for #{bybit_account.id}: #{e.message}"
    end

    begin
      process_account!
    rescue StandardError => e
      Rails.logger.error "BybitAccount::Processor - account update failed for #{bybit_account.id}: #{e.message}"
      raise
    end

    fetch_and_process_trades
  end

  private

    def target_currency
      bybit_account.bybit_item.family.currency
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(bybit_account.current_account)
    end

    def process_account!
      account  = bybit_account.current_account
      raw_usd  = (bybit_account.current_balance || 0).to_d
      amount, stale, rate_date = convert_from_usd(raw_usd, date: Date.current)
      stale_extra = build_stale_extra(stale, rate_date, Date.current)

      account.update!(
        balance:      amount,
        cash_balance: 0,
        currency:     target_currency
      )

      bybit_account.update!(extra: bybit_account.extra.to_h.deep_merge(stale_extra))
    end

    def fetch_and_process_trades
      provider = bybit_account.bybit_item&.bybit_provider
      return unless provider

      cached = bybit_account.raw_transactions_payload&.dig("spot") || []
      cached_ids = cached.map { |t| t["execId"] }.to_set

      new_executions = fetch_new_executions(provider, cached)
      new_executions.reject! { |e| cached_ids.include?(e["execId"]) }

      # Process into DB first; only persist the cache once entries are written so a
      # failure mid-way is retried on the next sync.
      process_executions(new_executions) if new_executions.any?

      merged = cached + new_executions
      bybit_account.update!(raw_transactions_payload: {
        "spot"       => merged,
        "fetched_at" => Time.current.iso8601
      })
    end

    # Fetches executions newer than what is already cached, sliding forward in
    # <= 7-day windows and paginating each window via nextPageCursor.
    def fetch_new_executions(provider, cached)
      max_cached_time = cached.map { |t| t["execTime"].to_i }.max
      now_ms = (Time.current.to_f * 1000).to_i

      start_ms = if max_cached_time && max_cached_time.positive?
        max_cached_time + 1
      elsif bybit_account.bybit_item&.sync_start_date
        bybit_account.bybit_item.sync_start_date.to_time.to_i * 1000
      else
        ((Time.current - DEFAULT_LOOKBACK).to_f * 1000).to_i
      end

      all_new = []
      window_start = start_ms

      while window_start < now_ms
        window_end = [ window_start + (MAX_WINDOW.to_i * 1000), now_ms ].min
        all_new.concat(fetch_window(provider, window_start, window_end))
        window_start = window_end + 1
      end

      all_new
    end

    def fetch_window(provider, start_ms, end_ms)
      rows = []
      cursor = nil

      loop do
        result = provider.get_spot_executions(start_time: start_ms, end_time: end_ms, cursor: cursor)
        break unless result.is_a?(Hash)

        rows.concat(Array(result["list"]))
        cursor = result["nextPageCursor"].presence
        break if cursor.nil?
      end

      rows
    end

    def process_executions(executions)
      executions.each { |execution| process_execution(execution) }
    rescue StandardError => e
      Rails.logger.error "BybitAccount::Processor - execution processing failed: #{e.message}"
      raise
    end

    def process_execution(execution)
      symbol = execution["symbol"].to_s
      base_symbol = base_symbol_for(symbol)
      return if base_symbol.blank?

      quote_symbol = symbol.delete_prefix(base_symbol)
      ticker   = "CRYPTO:#{base_symbol}"
      security = BybitAccount::SecurityResolver.resolve(ticker, base_symbol)
      return unless security

      exec_id = execution["execId"]
      return if exec_id.blank?

      date      = Time.zone.at(execution["execTime"].to_i / 1000).to_date
      qty       = execution["execQty"].to_d
      price_raw = execution["execPrice"].to_d
      value_raw = execution["execValue"].presence&.to_d || (qty * price_raw)
      is_buy    = execution["side"].to_s.casecmp("Buy").zero?

      price_usd  = quote_to_usd(price_raw, quote_symbol, date: date)
      amount_usd = quote_to_usd(value_raw, quote_symbol, date: date)

      if price_usd.nil? || amount_usd.nil?
        Rails.logger.warn "BybitAccount::Processor - skipping execution #{exec_id}: could not convert #{quote_symbol} to USD"
        return
      end

      signed_qty    = is_buy ? qty : -qty
      signed_amount = is_buy ? -amount_usd.round(2) : amount_usd.round(2)

      import_adapter.import_trade(
        security:       security,
        quantity:       signed_qty,
        price:          price_usd,
        amount:         signed_amount,
        currency:       "USD",
        date:           date,
        name:           "#{is_buy ? 'Buy' : 'Sell'} #{qty.round(8)} #{base_symbol}",
        external_id:    "bybit_spot_#{exec_id}",
        source:         "bybit",
        activity_label: is_buy ? "Buy" : "Sell"
      )
    rescue StandardError => e
      Rails.logger.error "BybitAccount::Processor - failed to process execution #{execution["execId"]}: #{e.message}"
      raise
    end

    def base_symbol_for(symbol)
      quote = QUOTE_CURRENCIES.find { |q| symbol.end_with?(q) && symbol.length > q.length }
      quote ? symbol.delete_suffix(quote) : nil
    end

    # Converts an amount denominated in quote_symbol to USD.
    # Stablecoins are treated 1:1; other quotes use the current spot price with an
    # ExchangeRate fallback.
    def quote_to_usd(amount, quote_symbol, date: nil)
      return amount if quote_symbol.blank?
      return amount if BybitAccount::STABLECOINS.include?(quote_symbol)
      return amount if quote_symbol.upcase == "USD"

      provider = bybit_account.bybit_item&.bybit_provider
      if provider
        spot = provider.get_spot_price(quote_symbol)
        return (amount * spot.to_d).round(8) if spot.present?
      end

      fallback_rate = ExchangeRate.find_or_fetch_rate(from: quote_symbol, to: "USD", date: date || Date.current, cache: true)
      if fallback_rate.present?
        rate_val = fallback_rate.respond_to?(:rate) ? fallback_rate.rate : fallback_rate
        return (amount * rate_val.to_d).round(8)
      end

      nil
    rescue StandardError => e
      Rails.logger.warn "BybitAccount::Processor - could not convert #{quote_symbol} to USD: #{e.message}"
      nil
    end
end
