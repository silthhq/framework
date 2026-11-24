require "http/status"

module Silth
  # Base class of every Silth exception.
  class Error < Exception; end

  # An exception that maps to an HTTP status code. Raise it anywhere during a
  # request and the error handler renders the right response (HTML or JSON).
  class HTTPError < Error
    getter status : HTTP::Status
    getter headers = {} of String => String
    getter details : Hash(String, Array(String))?

    def initialize(@status : HTTP::Status, message : String? = nil, @details = nil)
      super(message || status.description || "HTTP #{status.code}")
    end

    def code : Int32
      status.code
    end
  end

  class BadRequest < HTTPError
    def initialize(message : String? = nil)
      super(HTTP::Status::BAD_REQUEST, message)
    end
  end

  class Unauthorized < HTTPError
    def initialize(message : String? = "Unauthenticated")
      super(HTTP::Status::UNAUTHORIZED, message)
    end
  end

  class Forbidden < HTTPError
    def initialize(message : String? = "This action is unauthorized")
      super(HTTP::Status::FORBIDDEN, message)
    end
  end

  class NotFound < HTTPError
    def initialize(message : String? = "Not Found")
      super(HTTP::Status::NOT_FOUND, message)
    end
  end

  class MethodNotAllowed < HTTPError
    def initialize(allowed : Array(String))
      super(HTTP::Status::METHOD_NOT_ALLOWED, "Method Not Allowed")
      headers["Allow"] = allowed.join(", ")
    end
  end

  class Conflict < HTTPError
    def initialize(message : String? = "Conflict")
      super(HTTP::Status::CONFLICT, message)
    end
  end

  class PayloadTooLarge < HTTPError
    def initialize(message : String? = "Payload Too Large")
      super(HTTP::Status::PAYLOAD_TOO_LARGE, message)
    end
  end

  class UnprocessableEntity < HTTPError
    def initialize(message : String? = "The given data was invalid", details : Hash(String, Array(String))? = nil)
      super(HTTP::Status::UNPROCESSABLE_ENTITY, message, details)
    end
  end

  class TooManyRequests < HTTPError
    getter retry_after : Int32

    def initialize(@retry_after : Int32 = 60, message : String? = "Too Many Requests")
      super(HTTP::Status::TOO_MANY_REQUESTS, message)
      headers["Retry-After"] = retry_after.to_s
    end
  end

  class ServiceUnavailable < HTTPError
    def initialize(message : String? = "Service Unavailable")
      super(HTTP::Status::SERVICE_UNAVAILABLE, message)
    end
  end

  class CSRFError < HTTPError
    def initialize(message : String? = "CSRF token mismatch")
      super(HTTP::Status.new(419), message)
    end
  end
end
