# frozen_string_literal: true

# Bybit V5 REST client.
# Implements HMAC-SHA256 request signing (X-BAPI-SIGN-TYPE: 1) for the
# spot wallet balance and execution (trade) history endpoints used to track
# spot positions. Mirrors the structure of Provider::Binance.
class Provider::Bybit
  include HTTParty
  extend SslConfigurable

  class Error < StandardError; end
  class AuthenticationError < Error; end
  class RateLimitError < Error; end
  class ApiError < Error; end

  # Pipelock false positive: the @api_key / @api_secret instance variables below
  # trigger a "Credential in URL" warning because Pipelock misreads the Ruby '@'
  # as the user:password@host delimiter in a URL. There are no credentials in any URL here.
  DEFAULT_BASE_URL = "https://api.bybit.com".freeze
  RECV_WINDOW = "5000".freeze

  # Bybit ret_codes that indicate auth/signature problems.
  AUTH_RET_CODES = [ 10003, 10004, 10005, 33004 ].freeze
  RATE_LIMIT_RET_CODE = 10006

  base_uri DEFAULT_BASE_URL
  default_options.merge!({ timeout: 30 }.merge(httparty_ssl_options))

  attr_reader :api_key, :api_secret

  def initialize(api_key:, api_secret:)
    @api_key = api_key
    @api_secret = api_secret
  end

  # Unified account wallet balance — requires signed request.
  # Returns the parsed `result` hash containing `list[].coin[]`.
  def get_wallet_balance(account_type: "UNIFIED")
    signed_get("/v5/account/wallet-balance", extra_params: { "accountType" => account_type })
  end

  # Public endpoint — current spot price for a coin quoted in USDT.
  # coin e.g. "BTC". Returns price string or nil on failure.
  def get_spot_price(coin)
    symbol = "#{coin}USDT"
    response = self.class.get("/v5/market/tickers", query: { category: "spot", symbol: symbol })
    result = handle_response(response)
    list = result.is_a?(Hash) ? Array(result["list"]) : []
    list.first&.dig("lastPrice")
  rescue StandardError => e
    Rails.logger.warn("Provider::Bybit: failed to fetch price for #{coin}: #{e.message}")
    nil
  end

  # Signed spot execution (fill) history.
  # start_time/end_time are unix milliseconds; the window must be <= 7 days.
  # Returns the parsed `result` hash with `list[]` and `nextPageCursor`.
  def get_spot_executions(symbol: nil, start_time:, end_time:, cursor: nil, limit: 100)
    params = {
      "category" => "spot",
      "startTime" => start_time.to_s,
      "endTime" => end_time.to_s,
      "limit" => limit.to_s
    }
    params["symbol"] = symbol if symbol.present?
    params["cursor"] = cursor if cursor.present?
    signed_get("/v5/execution/list", extra_params: params)
  end

  # Public server time (health check). Returns true when reachable.
  def healthy?
    response = self.class.get("/v5/market/time")
    handle_response(response).present?
  rescue StandardError
    false
  end

  private

    def signed_get(path, extra_params: {})
      timestamp = (Time.current.to_f * 1000).to_i.to_s
      query_string = URI.encode_www_form(extra_params.sort)

      # Bybit GET signature payload: timestamp + apiKey + recvWindow + queryString
      param_str = "#{timestamp}#{api_key}#{RECV_WINDOW}#{query_string}"
      signature = sign(param_str)

      response = self.class.get(
        path,
        query: query_string.presence,
        headers: auth_headers(timestamp, signature)
      )

      handle_response(response)
    end

    def sign(param_str)
      OpenSSL::HMAC.hexdigest("sha256", api_secret, param_str)
    end

    def auth_headers(timestamp, signature)
      {
        "X-BAPI-API-KEY" => api_key,
        "X-BAPI-TIMESTAMP" => timestamp,
        "X-BAPI-SIGN" => signature,
        "X-BAPI-SIGN-TYPE" => "1",
        "X-BAPI-RECV-WINDOW" => RECV_WINDOW
      }
    end

    # Bybit always returns HTTP 200 with a body envelope:
    #   { "retCode": 0, "retMsg": "OK", "result": {...}, "time": ... }
    # Errors are signalled via a non-zero retCode.
    def handle_response(response)
      if response.code == 429
        raise RateLimitError, "Rate limit exceeded"
      end

      parsed = response.parsed_response

      unless parsed.is_a?(Hash)
        raise ApiError, "Unexpected response (HTTP #{response.code})"
      end

      ret_code = parsed["retCode"]
      ret_msg  = parsed["retMsg"].presence || "Unknown error"

      return parsed["result"] if ret_code.to_i.zero?

      case ret_code.to_i
      when *AUTH_RET_CODES
        raise AuthenticationError, ret_msg
      when RATE_LIMIT_RET_CODE
        raise RateLimitError, ret_msg
      else
        raise ApiError, "#{ret_msg} (retCode #{ret_code})"
      end
    end
end
