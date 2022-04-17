# frozen_string_literal: true

class SprintIssueChangeData
  attr_reader :time, :action, :value, :issue, :story_points

  def initialize time:, action:, value:, issue:, story_points:
    @time = time
    @action = action
    @value = value
    @issue = issue
    @story_points = story_points
  end

  def eql?(other)
    (other.class == self.class) && (other.state == state)
  end

  def state
    instance_variables.map { |variable| instance_variable_get variable }
  end

  def inspect
    result = String.new
    result << 'SprintIssueChangeData('
    result << instance_variables.collect do |variable|
      "#{variable}=#{instance_variable_get(variable).inspect}"
    end.join(', ')
    result << ')'
    result
  end
end

class SprintBurndown < ChartBase
  attr_accessor :use_story_points

  def initialize
    super()
    @use_story_points = true
  end

  def run
    sprints = sprints_in_time_range
    return nil if sprints.empty?

    data_sets = []
    sprints.each_with_index do |sprint, index|
      color = %w[blue orange green red brown][index % 5]
      label = sprint.name
      data_sets << {
        label: label,
        data: process_one_sprint(sprint),
        fill: false,
        showLine: true,
        borderColor: color,
        backgroundColor: color,
        stepped: true,
        pointStyle: %w[rect circle] # First dot is visually different from the rest
      }
    end

    render(binding, __FILE__)
  end

  # select all the changes that are relevant for the sprint. If this issue never appears in this sprint then return [].
  def single_issue_change_data_for_story_points issue:, sprint:
    story_points = 0.0
    ever_in_sprint = false
    currently_in_sprint = false
    change_data = []

    issue_completed_time = cycletime.stopped_time(issue)
    completed_has_been_tracked = false

    issue.changes.each do |change|
      action = nil
      value = nil

      if change.sprint?
        # We can get two sprint changes in a row that tell us the same thing so we have to verify
        # that something actually changed.
        in_change_item = sprint_in_change_item(sprint, change)
        if currently_in_sprint == false && in_change_item
          action = :enter_sprint
          ever_in_sprint = true
          value = story_points
        elsif currently_in_sprint && in_change_item == false
          action = :leave_sprint
          value = -story_points
        end
        currently_in_sprint = in_change_item
      elsif change.story_points? && (issue_completed_time.nil? || change.time < issue_completed_time)
        action = :story_points
        story_points = change.value&.to_f || 0.0
        value = story_points - (change.old_value&.to_f || 0.0)
      elsif completed_has_been_tracked == false && change.time == issue_completed_time
        completed_has_been_tracked = true
        action = :issue_stopped
        value = -story_points
      end

      next unless action

      change_data << SprintIssueChangeData.new(
        time: change.time, issue: issue, action: action, value: value, story_points: story_points
      )
    end

    return [] unless ever_in_sprint

    change_data
  end

  def sprint_in_change_item sprint, change_item
    change_item.raw['to'].split(/\s*,\s*/).any? { |id| id.to_i == sprint.id }
  end

  def process_one_sprint sprint
    change_data = []
    issues.each do |issue|
      change_data += single_issue_change_data_for_story_points(issue: issue, sprint: sprint)
    end
    change_data.sort_by!(&:time)

    data_sets_for_sprint sprint: sprint, change_data_for_sprint: change_data
  end

  def data_sets_for_sprint sprint:, change_data_for_sprint:
    story_points = 0.0
    start_data_written = false
    data_set = []

    issues_currently_in_sprint = []

    change_data_for_sprint.each do |change_data|
      if start_data_written == false && change_data.time >= sprint.start_time
        data_set << {
          y: story_points,
          x: chart_format(sprint.start_time),
          title: "Sprint started with #{story_points} points"
        }
        start_data_written = true
      end

      case change_data.action
      when :enter_sprint
        issues_currently_in_sprint << change_data.issue.key
        story_points += change_data.story_points
      when :leave_sprint
        issues_currently_in_sprint.delete change_data.issue.key
        story_points -= change_data.story_points
      end

      next unless change_data.time >= sprint.start_time
      next if sprint.completed_time && change_data.time > sprint.completed_time

      message = nil
      case change_data.action
      when :story_points
        next unless issues_currently_in_sprint.include? change_data.issue.key

        story_points += change_data.value
        old_story_points = change_data.story_points - change_data.value
        message = "Story points changed from #{old_story_points} points to #{change_data.story_points} points"
      when :enter_sprint
        message = "Added to sprint with #{change_data.story_points || 'no'} points"
      when :issue_stopped
        story_points -= change_data.story_points
        message = "Completed with #{change_data.story_points || 'no'} points"
        issues_currently_in_sprint.delete change_data.issue.key
      when :leave_sprint
        message = "Removed from sprint with #{change_data.story_points || 'no'} points"
      else
        raise "Unexpected action: #{change_data.action}"
      end

      data_set << {
        y: story_points,
        x: chart_format(change_data.time),
        title: "#{change_data.issue.key} #{message}"
      }
    end

    unless start_data_written
      # There was nothing that triggered us to write the sprint started block so do it now.
      data_set << {
        y: story_points,
        x: chart_format(sprint.start_time),
        title: "Sprint started with #{story_points} points"
      }
    end

    if sprint.completed_time
      data_set << {
        y: story_points,
        x: chart_format(sprint.completed_time),
        title: "Sprint ended with #{story_points} points unfinished"
      }
    end

    data_set #.tap { |ds| puts '---', sprint.name, sprint.start_time; ds.each { |data| puts data.inspect } }
  end
end

