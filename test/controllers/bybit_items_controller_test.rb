require "test_helper"

class BybitItemsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @bybit_item = BybitItem.create!(
      family: @family,
      name: "Test Bybit",
      api_key: "test_key",
      api_secret: "test_secret"
    )
  end

  test "should destroy bybit item" do
    assert_difference("BybitItem.count", 0) do # doesn't delete immediately
      delete bybit_item_url(@bybit_item)
    end

    assert_redirected_to settings_providers_path
    @bybit_item.reload
    assert @bybit_item.scheduled_for_deletion?
  end

  test "should sync bybit item" do
    post sync_bybit_item_url(@bybit_item)
    assert_response :redirect
  end

  test "should show setup_accounts page" do
    get setup_accounts_bybit_item_url(@bybit_item)
    assert_response :success
  end

  test "complete_account_setup creates accounts for selected bybit_accounts" do
    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "Account.count", 1 do
      post complete_account_setup_bybit_item_url(@bybit_item), params: {
        selected_accounts: [ bybit_account.id ]
      }
    end

    assert_response :redirect

    bybit_account.reload
    assert_not_nil bybit_account.current_account
    assert_equal "Crypto", bybit_account.current_account.accountable_type
  end

  test "complete_account_setup rejects a future sync_start_date and sets flash alert" do
    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    future_date = (Date.current + 2.days).to_s

    post complete_account_setup_bybit_item_url(@bybit_item), params: {
      selected_accounts: [ bybit_account.id ],
      sync_start_date: future_date
    }

    @bybit_item.reload
    assert_nil @bybit_item.sync_start_date
    assert_equal "Sync start date must be a valid date in the past.", flash[:alert]
  end

  test "cannot access other family's bybit_item" do
    other_family = families(:empty)
    other_item = BybitItem.create!(
      family: other_family,
      name: "Other Bybit",
      api_key: "other_test_key",
      api_secret: "other_test_secret"
    )

    get setup_accounts_bybit_item_url(other_item)
    assert_response :not_found
  end

  test "link_existing_account links manual account to bybit_account" do
    manual_account = Account.create!(
      family: @family,
      name: "Manual Crypto",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    bybit_account = @bybit_item.bybit_accounts.create!(
      name: "Spot Portfolio",
      account_type: "spot",
      currency: "USD",
      current_balance: 1000.0
    )

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_bybit_items_url, params: {
        account_id: manual_account.id,
        bybit_account_id: bybit_account.id
      }
    end

    bybit_account.reload
    assert_equal manual_account, bybit_account.current_account
  end

  test "select_existing_account renders without layout" do
    account = Account.create!(
      family: @family,
      name: "Manual Account",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )

    get select_existing_account_bybit_items_url, params: { account_id: account.id }
    assert_response :success
  end

  test "non-admin cannot create bybit item" do
    sign_in users(:family_member)

    assert_no_difference "BybitItem.count" do
      post bybit_items_url, params: {
        bybit_item: { api_key: "k", api_secret: "s" }
      }
    end
  end
end
