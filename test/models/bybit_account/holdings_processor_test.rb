# frozen_string_literal: true

require "test_helper"

class BybitAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @family.update!(currency: "EUR")

    @item = BybitItem.create!(
      family: @family, name: "Bybit", api_key: "k", api_secret: "s"
    )
    @ba = @item.bybit_accounts.create!(
      name: "Bybit",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000,
      raw_payload: {
        "assets" => [ { "symbol" => "BTC", "total" => "0.5", "source" => "spot" } ]
      }
    )
    @account = Account.create!(
      family: @family,
      name: "Bybit",
      balance: 0,
      currency: "EUR",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @ba)
  end

  test "converts holding amount to family currency when exact rate exists" do
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR",
                         date: Date.current, rate: 0.92)

    Security.find_or_create_by!(ticker: "CRYPTO:BTC") do |s|
      s.name = "BTC"
      s.exchange_operating_mic = "XBYB"
    end

    BybitAccount::HoldingsProcessor.any_instance
      .stubs(:fetch_price).with("BTC").returns(60_000.0)

    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(currency: "EUR", amount: 27_600.0)
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BybitAccount::HoldingsProcessor.new(@ba).process
  end

  test "treats stablecoins as 1 USD" do
    @ba.update!(raw_payload: { "assets" => [ { "symbol" => "USDT", "total" => "500", "source" => "spot" } ] })
    @family.update!(currency: "USD")

    Security.find_or_create_by!(ticker: "CRYPTO:USDT") do |s|
      s.name = "USDT"
      s.exchange_operating_mic = "XBYB"
    end

    import_adapter = mock
    import_adapter.expects(:import_holding).with(
      has_entries(currency: "USD", amount: 500.0)
    )
    Account::ProviderImportAdapter.stubs(:new).returns(import_adapter)

    BybitAccount::HoldingsProcessor.new(@ba).process
  end
end
