# frozen_string_literal: true

# Orchestrates the Bybit spot importer and upserts a single BybitAccount.
class BybitItem::Importer
  attr_reader :bybit_item, :bybit_provider

  def initialize(bybit_item, bybit_provider:)
    @bybit_item = bybit_item
    @bybit_provider = bybit_provider
  end

  def import
    Rails.logger.info "BybitItem::Importer #{bybit_item.id} - starting import"

    spot_result = BybitItem::SpotImporter.new(bybit_item, provider: bybit_provider).import
    all_assets  = tagged_assets(spot_result)

    return { success: true, assets_imported: 0, total_usd: 0 } if all_assets.empty?

    total_usd = calculate_total_usd(all_assets)

    upsert_bybit_account(all_assets: all_assets, total_usd: total_usd, spot_raw: spot_result[:raw])

    bybit_item.upsert_bybit_snapshot!({
      "spot" => spot_result[:raw],
      "imported_at" => Time.current.iso8601
    })

    Rails.logger.info "BybitItem::Importer #{bybit_item.id} - imported #{all_assets.size} assets, total_usd=#{total_usd}"

    { success: true, assets_imported: all_assets.size, total_usd: total_usd }
  end

  private

    def tagged_assets(result)
      result[:assets].map { |a| a.merge(source: result[:source]) }
    end

    def calculate_total_usd(assets)
      assets.sum do |asset|
        # Prefer the usdValue Bybit already computed to avoid extra price calls.
        next asset[:usd_value].to_d if asset[:usd_value].present?

        quantity = asset[:total].to_d
        next 0 if quantity.zero?

        quantity * price_for(asset[:symbol])
      end.round(2)
    end

    def price_for(symbol)
      return 1.0 if BybitAccount::STABLECOINS.include?(symbol)

      price = bybit_provider.get_spot_price(symbol)
      price.to_d
    rescue => e
      Rails.logger.warn "BybitItem::Importer - could not get price for #{symbol}: #{e.message}"
      0
    end

    def upsert_bybit_account(all_assets:, total_usd:, spot_raw:)
      ba = bybit_item.bybit_accounts.find_or_initialize_by(account_type: "spot")

      ba.assign_attributes(
        name: bybit_item.institution_name.presence || "Bybit",
        currency: "USD",
        current_balance: total_usd,
        institution_metadata: build_institution_metadata(all_assets),
        raw_payload: {
          "spot" => spot_raw,
          "assets" => all_assets.map(&:stringify_keys),
          "fetched_at" => Time.current.iso8601
        }
      )

      ba.save!
      ba
    end

    def build_institution_metadata(all_assets)
      {
        "spot" => {
          "asset_count" => all_assets.size,
          "assets" => all_assets.map { |a| a[:symbol] }
        }
      }
    end
end
