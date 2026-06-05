# frozen_string_literal: true

# Resolves or creates a Security for a given Bybit ticker.
# First attempts Security::Resolver; on failure, falls back to find_or_initialize_by
# and saves an offline security so syncs are not blocked by provider outages.
class BybitAccount::SecurityResolver
  EXCHANGE_MIC = "XBYB"

  def self.resolve(ticker, symbol)
    result = Security::Resolver.new(ticker).resolve
    if result.nil?
      Rails.logger.debug "BybitAccount::SecurityResolver - primary resolver returned nil for #{ticker}"
    end
    result
  rescue StandardError => e
    Rails.logger.warn "BybitAccount::SecurityResolver - resolver failed for #{ticker}: #{e.message}"
    Security.find_or_initialize_by(ticker: ticker, exchange_operating_mic: EXCHANGE_MIC).tap do |sec|
      sec.name = symbol if sec.name.blank?
      sec.offline = true unless sec.offline
      sec.save! if sec.changed?
    end
  end
end
