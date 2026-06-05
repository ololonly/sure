# frozen_string_literal: true

require "test_helper"

class BybitItem::SpotImporterTest < ActiveSupport::TestCase
  setup do
    @provider = mock
    @family = families(:dylan_family)
    @item = BybitItem.create!(family: @family, name: "B", api_key: "k", api_secret: "s")
  end

  test "returns normalized assets with source=spot" do
    @provider.stubs(:get_wallet_balance).returns({
      "list" => [
        {
          "coin" => [
            { "coin" => "BTC", "walletBalance" => "0.5", "usdValue" => "30000" },
            { "coin" => "ETH", "walletBalance" => "10", "usdValue" => "25000" },
            { "coin" => "XRP", "walletBalance" => "0", "usdValue" => "0" }
          ]
        }
      ]
    })

    result = BybitItem::SpotImporter.new(@item, provider: @provider).import

    assert_equal "spot", result[:source]
    assert_equal 2, result[:assets].size  # zero-balance XRP filtered out
    btc = result[:assets].find { |a| a[:symbol] == "BTC" }
    assert_equal "0.5", btc[:total]
    assert_equal "30000", btc[:usd_value]
  end

  test "returns empty assets on API error" do
    @provider.stubs(:get_wallet_balance).raises(Provider::Bybit::AuthenticationError, "Invalid key")

    result = BybitItem::SpotImporter.new(@item, provider: @provider).import

    assert_equal "spot", result[:source]
    assert_equal [], result[:assets]
    assert_nil result[:raw]
  end

  test "handles empty coin list" do
    @provider.stubs(:get_wallet_balance).returns({ "list" => [ { "coin" => [] } ] })

    result = BybitItem::SpotImporter.new(@item, provider: @provider).import

    assert_equal [], result[:assets]
  end
end
