# Live component: state lives on the server, the browser receives HTML diffs.
class CounterComponent < Silth::LiveComponent
  prop count : Int32 = 0
  prop step : Int32 = 1, writable: true
  template "components/counter"

  action def increment
    @count = count + step
  end

  action def decrement
    @count = count - step
  end

  action def reset
    @count = 0
    emit "toast", {message: "Counter reset", variant: "success"} # shown by UI::Toaster
  end
end
