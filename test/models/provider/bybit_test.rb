require "test_helper"

class Provider::BybitTest < ActiveSupport::TestCase
  setup do
    @provider = Provider::Bybit.new(api_key: "test_key", api_secret: "test_secret")
  end

  test "sign produces HMAC-SHA256 hex digest of the param string" do
    param_str = "1000test_key5000accountType=UNIFIED"
    sig = @provider.send(:sign, param_str)
    expected = OpenSSL::HMAC.hexdigest("sha256", "test_secret", param_str)
    assert_equal expected, sig
  end

  test "auth_headers include the required Bybit signing headers" do
    headers = @provider.send(:auth_headers, "1000", "abc123")
    assert_equal "test_key", headers["X-BAPI-API-KEY"]
    assert_equal "1000", headers["X-BAPI-TIMESTAMP"]
    assert_equal "abc123", headers["X-BAPI-SIGN"]
    assert_equal "1", headers["X-BAPI-SIGN-TYPE"]
    assert_equal "5000", headers["X-BAPI-RECV-WINDOW"]
  end

  test "handle_response returns result on retCode 0" do
    response = mock_response(200, { "retCode" => 0, "retMsg" => "OK", "result" => { "list" => [] } })
    assert_equal({ "list" => [] }, @provider.send(:handle_response, response))
  end

  test "handle_response raises AuthenticationError on auth retCodes" do
    response = mock_response(200, { "retCode" => 10003, "retMsg" => "Invalid API key" })
    assert_raises(Provider::Bybit::AuthenticationError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises RateLimitError on retCode 10006" do
    response = mock_response(200, { "retCode" => 10006, "retMsg" => "Too many visits" })
    assert_raises(Provider::Bybit::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises RateLimitError on HTTP 429" do
    response = mock_response(429, {})
    assert_raises(Provider::Bybit::RateLimitError) do
      @provider.send(:handle_response, response)
    end
  end

  test "handle_response raises ApiError on other non-zero retCodes" do
    response = mock_response(200, { "retCode" => 110001, "retMsg" => "Order does not exist" })
    assert_raises(Provider::Bybit::ApiError) do
      @provider.send(:handle_response, response)
    end
  end

  private

    def mock_response(code, body)
      response = mock
      response.stubs(:code).returns(code)
      response.stubs(:parsed_response).returns(body)
      response
    end
end
