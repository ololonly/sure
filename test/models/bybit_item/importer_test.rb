# frozen_string_literal: true

require "test_helper"

class BybitItem::ImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BybitItem.create!(family: @family, name: "Bybit", api_key: "k", api_secret: "s")
  end

  test "upserts a single spot BybitAccount and uses usdValue for total" do
    @provider.stubs(:get_wallet_balance).returns({
      "list" => [
        {
          "coin" => [
            { "coin" => "BTC", "walletBalance" => "0.5", "usdValue" => "30000" },
            { "coin" => "USDT", "walletBalance" => "1000", "usdValue" => "1000" }
          ]
        }
      ]
    })

    result = nil
    assert_difference "@item.bybit_accounts.count", 1 do
      result = BybitItem::Importer.new(@item, bybit_provider: @provider).import
    end

    assert result[:success]
    assert_equal 2, result[:assets_imported]
    assert_equal 31_000.to_d, result[:total_usd]

    ba = @item.bybit_accounts.find_by(account_type: "spot")
    assert_equal "USD", ba.currency
    assert_equal 31_000.to_d, ba.current_balance
    assert_equal 2, ba.raw_payload["assets"].size
  end

  test "falls back to spot price when usdValue is missing" do
    @provider.stubs(:get_wallet_balance).returns({
      "list" => [
        { "coin" => [ { "coin" => "BTC", "walletBalance" => "2", "usdValue" => nil } ] }
      ]
    })
    @provider.stubs(:get_spot_price).with("BTC").returns("50000")

    result = BybitItem::Importer.new(@item, bybit_provider: @provider).import

    assert_equal 100_000.to_d, result[:total_usd]
  end

  test "returns zero result when no assets" do
    @provider.stubs(:get_wallet_balance).returns({ "list" => [ { "coin" => [] } ] })

    assert_no_difference "@item.bybit_accounts.count" do
      result = BybitItem::Importer.new(@item, bybit_provider: @provider).import
      assert_equal 0, result[:assets_imported]
    end
  end
end
