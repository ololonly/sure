require "test_helper"
require "support/provider_adapter_test_interface"

class Provider::BybitAdapterTest < ActiveSupport::TestCase
  include ProviderAdapterTestInterface

  setup do
    @family = families(:dylan_family)
    @item = BybitItem.create!(
      family: @family,
      name: "Bybit",
      api_key: "k",
      api_secret: "s",
      institution_name: "Bybit",
      institution_domain: "bybit.com",
      institution_url: "https://www.bybit.com",
      institution_color: "#F7A600"
    )
    @bybit_account = @item.bybit_accounts.create!(
      name: "Bybit",
      account_type: "spot",
      currency: "USD",
      current_balance: 0
    )
    @account = Account.create!(
      family: @family,
      name: "Bybit",
      balance: 0,
      currency: "USD",
      accountable: Crypto.create!(subtype: "exchange")
    )
    AccountProvider.create!(account: @account, provider: @bybit_account)

    @adapter = Provider::BybitAdapter.new(@bybit_account, account: @account)
  end

  def adapter
    @adapter
  end

  test_provider_adapter_interface
  test_syncable_interface
  test_institution_metadata_interface

  test "supports Crypto account type" do
    assert_equal %w[Crypto], Provider::BybitAdapter.supported_account_types
  end

  test "build_provider returns a Provider::Bybit when credentials are configured" do
    provider = Provider::BybitAdapter.build_provider(family: @family)
    assert_kind_of Provider::Bybit, provider
  end

  test "connection_configs exposes a bybit entry" do
    configs = Provider::BybitAdapter.connection_configs(family: @family)
    assert_equal 1, configs.size
    assert_equal "bybit", configs.first[:key]
  end
end
