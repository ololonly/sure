# frozen_string_literal: true

# Broadcasts Turbo Stream updates when a Bybit sync completes.
# Updates account views and notifies the family of sync completion.
class BybitItem::SyncCompleteEvent
  attr_reader :bybit_item

  # @param bybit_item [BybitItem] The item that completed syncing
  def initialize(bybit_item)
    @bybit_item = bybit_item
  end

  # Broadcasts sync completion to update UI components.
  def broadcast
    # Update UI with latest account data
    bybit_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    # Update the Bybit item view
    bybit_item.broadcast_replace_to(
      bybit_item.family,
      target: "bybit_item_#{bybit_item.id}",
      partial: "bybit_items/bybit_item",
      locals: { bybit_item: bybit_item }
    )

    # Let family handle sync notifications
    bybit_item.family.broadcast_sync_complete
  end
end
