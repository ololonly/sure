# frozen_string_literal: true

require "test_helper"

class BybitAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "USD")

    @item = BybitItem.create!(family: @family, name: "Bybit", api_key: "k", api_secret: "s")
    @item.update!(sync_start_date: 2.days.ago)

    @ba = @item.bybit_accounts.create!(
      name: "Bybit",
      account_type: "spot",
      currency: "USD",
      current_balance: 1234.56,
      raw_payload: { "assets" => [] }
    )
    @account = Account.create!(
      family: @family,
      name: "Bybit",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)

    @provider = mock
    BybitItem.any_instance.stubs(:bybit_provider).returns(@provider)
    # Holdings are covered by their own test; isolate trade handling here.
    BybitAccount::HoldingsProcessor.any_instance.stubs(:process)
  end

  test "updates the linked account balance from current_balance" do
    @provider.stubs(:get_spot_executions).returns({ "list" => [], "nextPageCursor" => nil })

    BybitAccount::Processor.new(@ba).process

    assert_equal 1234.56.to_d, @account.reload.balance
    assert_equal 0, @account.cash_balance
  end

  test "imports spot executions as trades and caches them" do
    execution = {
      "symbol" => "BTCUSDT",
      "side" => "Buy",
      "execId" => "exec-1",
      "execQty" => "0.01",
      "execPrice" => "50000",
      "execValue" => "500",
      "execTime" => (Time.current.to_f * 1000).to_i.to_s
    }
    @provider.stubs(:get_spot_executions).returns({ "list" => [ execution ], "nextPageCursor" => nil })

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBYB"
    end

    import_adapter = mock
    import_adapter.expects(:import_trade).with(
      has_entries(
        currency: "USD",
        amount: -500.0,
        external_id: "bybit_spot_exec-1",
        source: "bybit"
      )
    ).once
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BybitAccount::Processor.new(@ba).process

    cached = @ba.reload.raw_transactions_payload["spot"]
    assert_equal 1, cached.size
    assert_equal "exec-1", cached.first["execId"]
  end

  test "skips executions already cached by execId" do
    recent_ms = ((Time.current - 1.day).to_f * 1000).to_i.to_s
    @ba.update!(raw_transactions_payload: { "spot" => [ { "execId" => "exec-1", "execTime" => recent_ms } ] })

    execution = {
      "symbol" => "BTCUSDT", "side" => "Buy", "execId" => "exec-1",
      "execQty" => "0.01", "execPrice" => "50000", "execValue" => "500",
      "execTime" => (Time.current.to_f * 1000).to_i.to_s
    }
    @provider.stubs(:get_spot_executions).returns({ "list" => [ execution ], "nextPageCursor" => nil })

    import_adapter = mock
    import_adapter.expects(:import_trade).never
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BybitAccount::Processor.new(@ba).process
  end
end
