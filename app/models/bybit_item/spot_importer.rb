# frozen_string_literal: true

# Fetches Bybit unified-account spot wallet balances.
# Returns normalized asset list with source tag "spot".
class BybitItem::SpotImporter
  attr_reader :bybit_item, :provider

  def initialize(bybit_item, provider:)
    @bybit_item = bybit_item
    @provider = provider
  end

  # @return [Hash] { assets: [...], raw: <api_response>, source: "spot" }
  def import
    raw = provider.get_wallet_balance(account_type: "UNIFIED")
    coins = raw.is_a?(Hash) ? Array(raw["list"]).first&.dig("coin") : nil
    { assets: parse_assets(coins || []), raw: raw, source: "spot" }
  rescue => e
    Rails.logger.error "BybitItem::SpotImporter #{bybit_item.id} - #{e.message}"
    { assets: [], raw: nil, source: "spot", error: e.message }
  end

  private

    def parse_assets(coins)
      coins.filter_map do |c|
        total = c["walletBalance"].to_d
        next if total.zero?

        {
          symbol: c["coin"],
          total: total.to_s("F"),
          usd_value: c["usdValue"].presence
        }
      end
    end
end
