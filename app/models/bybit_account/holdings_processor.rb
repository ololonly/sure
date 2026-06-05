# frozen_string_literal: true

# Creates/updates Holdings for each asset in the spot BybitAccount.
# One Holding per coin.
class BybitAccount::HoldingsProcessor
  include BybitAccount::UsdConverter

  def initialize(bybit_account)
    @bybit_account = bybit_account
  end

  def process
    unless account&.accountable_type == "Crypto"
      Rails.logger.info "BybitAccount::HoldingsProcessor - skipping: not a Crypto account"
      return
    end

    assets = raw_assets
    if assets.empty?
      Rails.logger.info "BybitAccount::HoldingsProcessor - no assets in payload"
      return
    end

    assets.each { |asset| process_asset(asset) }
  rescue StandardError => e
    Rails.logger.error "BybitAccount::HoldingsProcessor - error: #{e.message}"
    nil
  end

  private

    attr_reader :bybit_account

    def target_currency
      bybit_account.bybit_item.family.currency
    end

    def account
      bybit_account.current_account
    end

    def raw_assets
      bybit_account.raw_payload&.dig("assets") || []
    end

    def process_asset(asset)
      symbol = asset["symbol"] || asset[:symbol]
      return if symbol.blank?

      total  = (asset["total"] || asset[:total]).to_d
      source = asset["source"] || asset[:source] || "spot"

      return if total.zero?

      ticker   = symbol.include?(":") ? symbol : "CRYPTO:#{symbol}"
      security = resolve_security(ticker, symbol)
      return unless security

      price_usd = fetch_price(symbol)
      return if price_usd.nil?

      amount_usd = total * price_usd

      # Stale rate metadata is intentionally discarded here — it is captured and
      # surfaced at the account level by BybitAccount::Processor#process_account!.
      amount, _stale, _rate_date = convert_from_usd(amount_usd, date: Date.current)
      price, _, _ = convert_from_usd(price_usd, date: Date.current)

      import_adapter.import_holding(
        security:               security,
        quantity:               total,
        amount:                 amount,
        currency:               target_currency,
        date:                   Date.current,
        price:                  price,
        cost_basis:             nil,
        external_id:            "bybit_#{symbol}_#{source}_#{Date.current}",
        account_provider_id:    bybit_account.account_provider&.id,
        source:                 "bybit",
        delete_future_holdings: false
      )

      Rails.logger.info "BybitAccount::HoldingsProcessor - imported #{total} #{symbol} @ #{price_usd} USD → #{amount} #{target_currency}"
    rescue StandardError => e
      Rails.logger.error "BybitAccount::HoldingsProcessor - failed asset #{asset}: #{e.message}"
    end

    def import_adapter
      @import_adapter ||= Account::ProviderImportAdapter.new(account)
    end

    def resolve_security(ticker, symbol)
      BybitAccount::SecurityResolver.resolve(ticker, symbol)
    end

    def fetch_price(symbol)
      return 1.0 if BybitAccount::STABLECOINS.include?(symbol)

      provider = bybit_account.bybit_item&.bybit_provider
      return nil unless provider

      price_str = provider.get_spot_price(symbol)
      return price_str.to_d if price_str.present?

      Rails.logger.warn "BybitAccount::HoldingsProcessor - no price found for #{symbol}; skipping holding"
      nil
    end
end
