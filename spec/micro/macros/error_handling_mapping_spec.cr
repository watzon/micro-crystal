require "../../spec_helper"

describe Micro::Macros::ErrorHandling do
  it "maps specific errors to status codes" do
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::BadRequestError.new).should eq 400
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::NotFoundError.new).should eq 404
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::UnauthorizedError.new).should eq 401
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::ForbiddenError.new).should eq 403
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::ConflictError.new).should eq 409
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::ValidationError.new).should eq 422
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::RateLimitError.new).should eq 429
    Micro::Macros::ErrorHandling.status_for_error(Micro::Core::ServiceUnavailableError.new).should eq 503
    Micro::Macros::ErrorHandling.status_for_error(IO::TimeoutError.new).should eq 504
  end

  it "defaults to 500 for generic exceptions" do
    Micro::Macros::ErrorHandling.status_for_error(Exception.new("boom")).should eq 500
  end

  it "formats validation and rate limit error responses with extra fields" do
    val = Micro::Core::ValidationError.new("invalid", {"name" => ["required"]})
    body = Micro::Macros::ErrorHandling.format_error_response(val)
    body["error"].should contain("invalid")
    body["type"].should eq(Micro::Core::ValidationError.name)
    body["validation_errors"]?.should_not be_nil

    rl = Micro::Core::RateLimitError.new("slow down", 3)
    rbody = Micro::Macros::ErrorHandling.format_error_response(rl)
    rbody["error"].should contain("slow down")
    rbody["type"].should eq(Micro::Core::RateLimitError.name)
    rbody["retry_after"]?.should eq("3")
  end
end
