class AlertInterface
  @events = nil
  @from = nil
  @target = nil

  def initialize(
      events,
      from,
      target
  )

    @events = events
    @from = from
    @target = target
  end

  def send(*args)
    abort 'not implemented'
  end
end
