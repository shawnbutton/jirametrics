# frozen_string_literal: true

require 'time'

class Issue
  attr_reader :changes, :raw, :subtasks, :board
  attr_accessor :parent

  def initialize raw:, board:, timezone_offset: '+00:00'
    @raw = raw
    @timezone_offset = timezone_offset
    @subtasks = []
    @changes = []
    @board = board

    return unless @raw['changelog']

    load_history_into_changes

    # If this is an older pull of data then comments may not be there.
    load_comments_into_changes if @raw['fields']['comment']

    # It might appear that Jira already returns these in order but we've found different
    # versions of Server/Cloud return the changelog in different orders so we sort them.
    sort_changes!

    # It's possible to have a ticket created with certain things already set and therefore
    # not showing up in the change log. Create some artificial entries to capture those.
    @changes = [
      fabricate_change(field_name: 'status'),
      fabricate_change(field_name: 'priority')
    ].compact + @changes
  end

  def sort_changes!
    @changes.sort! do |a, b|
      # It's common that a resolved will happen at the same time as a status change.
      # Put them in a defined order so tests can be deterministic.
      compare = a.time <=> b.time
      compare = 1 if compare.zero? && a.resolution?
      compare
    end
  end

  def key = @raw['key']

  def type = @raw['fields']['issuetype']['name']

  def type_icon_url = @raw['fields']['issuetype']['iconUrl']

  def summary = @raw['fields']['summary']

  def status
    raw_status = @raw['fields']['status']
    raw_category = raw_status['statusCategory']

    Status.new(
      name: raw_status['name'],
      id: raw_status['id'].to_i,
      category_name: raw_category['name'],
      category_id: raw_category['id'].to_i
    )
  end

  def status_id
    puts 'DEPRECATED(Issue.status_id) Call Issue.status.id instead'
    status.id
  end

  def labels = @raw['fields']['labels'] || []

  def author = @raw['fields']['creator']['displayName']

  def resolution = @raw['fields']['resolution']&.[]('name')

  def url
    # Strangely, the URL isn't anywhere in the returned data so we have to fabricate it.
    "#{$1}/browse/#{key}" if @raw['self'] =~ /^(https?:\/\/[^\/]+)\//
  end

  def key_as_i
    $1.to_i if key =~ /-(\d+)$/
  end

  def component_names
    @raw['fields']['components']&.collect { |component| component['name'] } || []
  end

  def fabricate_change field_name:
    first_status = nil
    first_status_id = nil

    created_time = parse_time @raw['fields']['created']
    first_change = @changes.find { |change| change.field == field_name }
    if first_change.nil?
      # There have been no changes of this type yet so we have to look at the current one
      return nil unless @raw['fields'][field_name]

      first_status = @raw['fields'][field_name]['name']
      first_status_id = @raw['fields'][field_name]['id'].to_i
    else
      # Otherwise, we look at what the first one had changed away from.
      first_status = first_change.old_value
      first_status_id = first_change.old_value_id
    end
    ChangeItem.new time: created_time, artificial: true, author: author, raw: {
      'field' => field_name,
      'to' => first_status_id,
      'toString' => first_status
    }
  end

  def first_time_in_status *status_names
    @changes.find { |change| change.matches_status status_names }&.time
  end

  def first_time_not_in_status *status_names
    @changes.find { |change| change.status? && status_names.include?(change.value) == false }&.time
  end

  def still_in
    time = nil
    @changes.each do |change|
      next unless change.status?

      current_status_matched = yield change

      if current_status_matched && time.nil?
        time = change.time
      elsif !current_status_matched && time
        time = nil
      end
    end
    time
  end
  private :still_in

  # If it ever entered one of these statuses and it's still there then what was the last time it entered
  def still_in_status *status_names
    still_in do |change|
      status_names.include?(change.value)
    end
  end

  # If it ever entered one of these categories and it's still there then what was the last time it entered
  def still_in_status_category *category_names
    still_in do |change|
      status = find_status_by_name change.value
      category_names.include? status.category_name
    end
  end

  def most_recent_status_change
    changes.reverse.find { |change| change.status? }
  end

  # Are we currently in this status? If yes, then return the time of the most recent status change.
  def currently_in_status *status_names
    change = most_recent_status_change
    return false if change.nil?

    change.time if change.matches_status status_names
  end

  # Are we currently in this status category? If yes, then return the time of the most recent status change.
  def currently_in_status_category *category_names
    change = most_recent_status_change
    return false if change.nil?

    status = find_status_by_name change.value
    change.time if status && category_names.include?(status.category_name)
  end

  def find_status_by_name name
    status = board.possible_statuses.find_by_name(name)
    return status if status

    raise "Status name #{name.inspect} not found in #{board.possible_statuses.collect(&:name).inspect}"
  end

  def first_status_change_after_created
    @changes.find { |change| change.status? && change.artificial? == false }&.time
  end

  def first_time_in_status_category *category_names
    @changes.each do |change|
      next unless change.status?

      category = board.possible_statuses.find_by_name(change.value).category_name
      return change.time if category_names.include? category
    end
    nil
  end

  def parse_time text
    Time.parse(text).getlocal(@timezone_offset)
  end

  def created
    parse_time @raw['fields']['created']
  end

  def updated
    parse_time @raw['fields']['updated']
  end

  def first_resolution
    @changes.find { |change| change.resolution? }&.time
  end

  def last_resolution
    @changes.reverse.find { |change| change.resolution? }&.time
  end

  def assigned_to
    @raw['fields']&.[]('assignee')&.[]('displayName')
  end

  # TODO: Change to use new cycletime_config
  def blocked_percentage started, finished
    started = started.call self
    finished = finished.call self

    return '' if started.nil? || finished.nil?

    total_blocked_time = 0
    blocked_start = nil

    @changes.each do |change|
      next unless change.flagged?

      if change.value == 'Blocked'
        blocked_start = change.time
      else
        # It shouldn't be possible to get an unblock without first being blocked but we've
        # seen it in production so we have to handle it. Data integrity FTW.
        next if blocked_start.nil?

        if change.time >= started
          blocked_start = started if blocked_start < started
          blocked_end = change.time
          blocked_end = finished if blocked_end > finished
          total_blocked_time += (blocked_end.to_time - blocked_start.to_time)
        end
        blocked_start = nil
      end
    end

    total_time = (finished.to_time - started.to_time)
    total_blocked_time * 100.0 / total_time
  end

  # Many test failures are simply unreadable because the default inspect on this class goes
  # on for pages. Shorten it up.
  def inspect
    "Issue(#{key.inspect})"
  end

  def blocked_on_date? date
    blocked_start = nil
    changes.each do |change|
      next unless change.flagged?

      if change.value == '' # Flag is turning off
        # It's theoretically impossible for us to get a flag turning off *before* it gets
        # turned on and yet, we've seen this exact scenario in a production system so we
        # have to handle it.
        next if blocked_start.nil?

        range = blocked_start.to_date..change.time.to_date
        return true if range.include? date

        blocked_start = nil
      else
        # Flag is turning on. Note that Jira may pass in a variety of different values here
        # but all we care about is that it isn't an empty string.
        blocked_start = change.time.to_date
      end
    end

    if blocked_start
      date >= blocked_start
    else
      false
    end
  end

  def stalled_on_date? date, stalled_threshold = 5
    # Did any changes happen within the threshold
    changes.each do |change|
      change_date = change.time.to_date
      next if change_date > date

      return false if (date - change_date).to_i < stalled_threshold
    end

    # Walk through all subtasks to see if any of them have been updated within
    # the threshold. This obviously only works if the subtasks are already loaded.
    @subtasks.each do |subtask|
      return false unless subtask.stalled_on_date?(date, stalled_threshold)
    end

    updated_date = updated.to_date
    return true if date < updated_date

    date >= updated_date && (date - updated_date).to_i >= stalled_threshold
  end

  def expedited?
    names = @board&.expedited_priority_names
    return false unless names

    current_priority = raw['fields']['priority']&.[]('name')
    names.include? current_priority
  end

  def expedited_on_date? date
    expedited_start = nil
    expedited_names = @board&.expedited_priority_names

    changes.each do |change|
      next unless change.priority?

      if expedited_names.include? change.value
        expedited_start = change.time.to_date if expedited_start.nil?
      else
        return true if expedited_start && (expedited_start..change.time.to_date).include?(date)

        expedited_start = nil
      end
    end

    return false if expedited_start.nil?

    expedited_start <= date
  end

  # Return the last time there was any activity on this ticket. Starting from "now" and going backwards
  # Returns nil if there was no activity before that time.
  def last_activity now: Time.now
    result = @changes.reverse.find { |change| change.time <= now }&.time

    # The only condition where this could be nil is if "now" is before creation
    return nil if result.nil?

    @subtasks.each do |subtask|
      subtask_last_activity = subtask.last_activity now: now
      result = subtask_last_activity if subtask_last_activity && subtask_last_activity > result
    end

    result
  end

  def issue_links
    if @issue_links.nil?
      @issue_links = @raw['fields']['issuelinks'].collect do |issue_link|
        IssueLink.new origin: self, raw: issue_link
      end
    end
    @issue_links
  end

  def fix_versions
    if @fix_versions.nil?
      @fix_versions = @raw['fields']['fixVersions']&.collect do |fix_version|
        FixVersion.new fix_version
      end || []
    end
    @fix_versions
  end

  def parent_key project_config: @board.project_config
    # Although Atlassian is trying to standardize on one way to determine the parent, today it's a mess.
    # We try a variety of ways to get the parent and hopefully one of them will work. See this link:
    # https://community.developer.atlassian.com/t/deprecation-of-the-epic-link-parent-link-and-other-related-fields-in-rest-apis-and-webhooks/54048

    fields = @raw['fields']

    # At some point in the future, this will be the only way to retrieve the parent so we try this first.
    parent = fields['parent']&.[]('key')

    # The epic field
    parent = fields['epic']&.[]('key') if parent.nil?

    # Otherwise the parent link will be stored in one of the custom fields. We've seen different custom fields
    # used for parent_link vs epic_link so we have to support more than one.
    if parent.nil? && project_config
      custom_field_names = project_config.settings['customfield_parent_links']
      custom_field_names = [custom_field_names] if custom_field_names.is_a? String

      custom_field_names&.each do |field_name|
        parent = fields[field_name]
        # A break would be more appropriate than a return but the runtime caused an error when we do that
        return parent if parent
      end
    end

    parent
  end

  def in_initial_query?
    @raw['exporter'].nil? || @raw['exporter']['in_initial_query']
  end

  # It's artificial if it wasn't downloaded from a Jira instance.
  def artificial?
    @raw['exporter'].nil?
  end

  private

  def assemble_author raw
    raw['author']&.[]('displayName') || raw['author']&.[]('name') || 'Unknown author'
  end

  def load_history_into_changes
    @raw['changelog']['histories'].each do |history|
      created = parse_time(history['created'])

      # It should be impossible to not have an author but we've seen it in production
      author = assemble_author history
      history['items'].each do |item|
        @changes << ChangeItem.new(raw: item, time: created, author: author)
      end
    end
  end

  def load_comments_into_changes
    @raw['fields']['comment']['comments'].each do |comment|
      raw = {
        'field' => 'comment',
        'to' => comment['id'],
        'toString' =>  comment['body']
      }
      author = assemble_author comment
      created = parse_time(comment['created'])
      @changes << ChangeItem.new(raw: raw, time: created, author: author, artificial: true)
    end
  end
end
