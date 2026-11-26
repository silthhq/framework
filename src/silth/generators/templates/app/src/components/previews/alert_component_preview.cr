# Component previews are listed in the profiler: /_silth/profiler/components.
# Each public method is a scenario returning the component to show.
class AlertComponentPreview < Silth::ComponentPreview
  description "Inline messages (flash-like), one per variant."

  def info : Silth::Component
    AlertComponent.new(message: "Your profile is public.", variant: "info")
  end

  def success : Silth::Component
    AlertComponent.new(message: "Saved.", variant: "success")
  end

  def error : Silth::Component
    AlertComponent.new(message: "Something went wrong.", variant: "error")
  end
end
