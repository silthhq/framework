# A live component: its buttons work in the preview too.
class CounterComponentPreview < Silth::ComponentPreview
  description "The live counter of the home page."

  def default : Silth::Component
    CounterComponent.new
  end

  def big_steps : Silth::Component
    CounterComponent.new(count: 100, step: 10)
  end
end
