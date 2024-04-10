# frozen_string_literal: true

require 'cgi'
require 'json'
require 'English'

class Downloader
  CURRENT_METADATA_VERSION = 4

  attr_accessor :metadata, :quiet_mode, :logfile, :logfile_name

  # For testing only
  attr_reader :start_date_in_query

  def initialize download_config:, json_file_loader: JsonFileLoader.new
    @metadata = {}
    @download_config = download_config
    @target_path = @download_config.project_config.target_path
    @json_file_loader = json_file_loader
    @board_id_to_filter_id = {}

    @issue_keys_downloaded_in_current_run = []
    @issue_keys_pending_download = []
  end

  def run
    log '', both: true
    log @download_config.project_config.name, both: true

    load_jira_config(@download_config.project_config.jira_config)
    load_metadata

    if @metadata['no-download']
      log '  Skipping download. Found no-download in meta file', both: true
      return
    end

    # board_ids = @download_config.board_ids

    remove_old_files
    download_statuses
    find_board_ids.each do |id|
      download_board_configuration board_id: id
      download_issues board_id: id
    end

    save_metadata
  end

  def log text, both: false
    @logfile&.puts text
    puts text if both
  end

  def find_board_ids
    ids = @download_config.project_config.board_configs.collect(&:id)
    if ids.empty?
      deprecated message: 'board_ids in the download block have been deprecated. See https://github.com/mikebowler/jira-export/wiki/Deprecated'
      ids = @download_config.board_ids
    end
    raise 'Board ids must be specified' if ids.empty?

    ids
  end

  def load_jira_config jira_config
    @jira_url = jira_config['url']
    @jira_email = jira_config['email']
    @jira_api_token = jira_config['api_token']
    @jira_personal_access_token = jira_config['personal_access_token']

    raise 'When specifying an api-token, you must also specify email' if @jira_api_token && !@jira_email

    if @jira_api_token && @jira_personal_access_token
      raise "You can't specify both an api-token and a personal-access-token. They don't work together."
    end

    @cookies = (jira_config['cookies'] || []).collect { |key, value| "#{key}=#{value}" }.join(';')
  end

  def call_command command
    log "  #{command.gsub(/\s+/, ' ')}"
    result = `#{command}`
    log result unless $CHILD_STATUS.success?
    return result if $CHILD_STATUS.success?

    log "Failed call with exit status #{$CHILD_STATUS.exitstatus}. See #{@logfile_name} for details", both: true
    exit $CHILD_STATUS.exitstatus
  end

  def make_curl_command url:
    command = 'curl'
    command += ' -s'
    command += ' -k' if @download_config.project_config.settings['ignore_ssl_errors']
    command += " --cookie #{@cookies.inspect}" unless @cookies.empty?
    command += " --user #{@jira_email}:#{@jira_api_token}" if @jira_api_token
    command += " -H \"Authorization: Bearer #{@jira_personal_access_token}\"" if @jira_personal_access_token
    command += ' --request GET'
    command += ' --header "Accept: application/json"'
    command += " --url \"#{url}\""
    command
  end

  def download_issues board_id:
    log "  Downloading primary issues for board #{board_id}", both: true
    path = "#{@target_path}#{@download_config.project_config.file_prefix}_issues/"
    unless Dir.exist?(path)
      log "  Creating path #{path}"
      Dir.mkdir(path)
    end

    filter_id = @board_id_to_filter_id[board_id]
    jql = make_jql(filter_id: filter_id)
    jira_search_by_jql(jql: jql, initial_query: true, board_id: board_id, path: path)

    log "  Downloading linked issues for board #{board_id}", both: true
    loop do
      @issue_keys_pending_download.reject! { |key| @issue_keys_downloaded_in_current_run.include? key }
      break if @issue_keys_pending_download.empty?

      keys_to_request = @issue_keys_pending_download[0..99]
      @issue_keys_pending_download.reject! { |key| keys_to_request.include? key }
      jql = "key in (#{keys_to_request.join(', ')})"
      jira_search_by_jql(jql: jql, initial_query: false, board_id: board_id, path: path)
    end
  end

  def jira_search_by_jql jql:, initial_query:, board_id:, path:
    intercept_jql = @download_config.project_config.settings['intercept_jql']
    jql = intercept_jql.call jql if intercept_jql

    log "  #{jql}"
    escaped_jql = CGI.escape jql

    max_results = 100
    start_at = 0
    total = 1
    while start_at < total
      command = make_curl_command url: "#{@jira_url}/rest/api/2/search" \
        "?jql=#{escaped_jql}&maxResults=#{max_results}&startAt=#{start_at}&expand=changelog&fields=*all"

      json = JSON.parse call_command(command)
      exit_if_call_failed json

      json['issues'].each do |issue_json|
        issue_json['exporter'] = {
          'in_initial_query' => initial_query
        }
        identify_other_issues_to_be_downloaded issue_json
        file = "#{issue_json['key']}-#{board_id}.json"
        write_json(issue_json, File.join(path, file))
      end

      total = json['total'].to_i
      max_results = json['maxResults']

      message = "    Downloaded #{start_at + 1}-#{[start_at + max_results, total].min} of #{total} issues to #{path} "
      log message, both: true

      start_at += json['issues'].size
    end
  end

  def identify_other_issues_to_be_downloaded raw_issue
    issue = Issue.new raw: raw_issue, board: nil
    @issue_keys_downloaded_in_current_run << issue.key

    # Parent
    parent_key = issue.parent_key(project_config: @download_config.project_config)
    @issue_keys_pending_download << parent_key if parent_key

    # Sub-tasks
    issue.raw['fields']['subtasks']&.each do |raw_subtask|
      @issue_keys_pending_download << raw_subtask['key']
    end

    # Links
    # We shouldn't blindly follow links as some, like cloners, aren't valuable and are just wasting time/effort
    # to download
    # issue.raw['fields']['issuelinks'].each do |raw_link|
    #   @issue_keys_pending_download << IssueLink(raw: raw_link).other_issue.key
    # end
  end

  def exit_if_call_failed json
    # Sometimes Jira returns the singular form of errorMessage and sometimes the plural. Consistency FTW.
    return unless json['errorMessages'] || json['errorMessage']

    log "Download failed. See #{@logfile_name} for details.", both: true
    log "  #{JSON.pretty_generate(json)}"
    exit 1
  end

  def download_statuses
    log '  Downloading all statuses', both: true
    command = make_curl_command url: "\"#{@jira_url}/rest/api/2/status\""
    json = JSON.parse call_command(command)

    write_json json, "#{@target_path}#{@download_config.project_config.file_prefix}_statuses.json"
  end

  def download_board_configuration board_id:
    log "  Downloading board configuration for board #{board_id}", both: true
    command = make_curl_command url: "#{@jira_url}/rest/agile/1.0/board/#{board_id}/configuration"

    json = JSON.parse call_command(command)
    exit_if_call_failed json

    @board_id_to_filter_id[board_id] = json['filter']['id'].to_i
    # @board_configuration = json if @download_config.board_ids.size == 1

    file_prefix = @download_config.project_config.file_prefix
    write_json json, "#{@target_path}#{file_prefix}_board_#{board_id}_configuration.json"

    download_sprints board_id: board_id if json['type'] == 'scrum'
  end

  def download_sprints board_id:
    log "  Downloading sprints for board #{board_id}", both: true
    file_prefix = @download_config.project_config.file_prefix
    max_results = 100
    start_at = 0
    is_last = false

    while is_last == false
      command = make_curl_command url: "#{@jira_url}/rest/agile/1.0/board/#{board_id}/sprint?" \
        "maxResults=#{max_results}&startAt=#{start_at}"
      json = JSON.parse call_command(command)
      exit_if_call_failed json

      write_json json, "#{@target_path}#{file_prefix}_board_#{board_id}_sprints_#{start_at}.json"
      is_last = json['isLast']
      max_results = json['maxResults']
      start_at += json['values'].size
    end
  end

  def write_json json, filename
    file_path = File.dirname(filename)
    FileUtils.mkdir_p file_path unless File.exist?(file_path)

    File.write(filename, JSON.pretty_generate(json))
  end

  def metadata_pathname
    "#{@target_path}#{@download_config.project_config.file_prefix}_meta.json"
  end

  def load_metadata
    # If we've never done a download before then this file won't be there. That's ok.
    return unless File.exist? metadata_pathname

    hash = JSON.parse(File.read metadata_pathname)

    # Only use the saved metadata if the version number is the same one that we're currently using.
    # If the cached data is in an older format then we're going to throw most of it away.
    @cached_data_format_is_current = (hash['version'] || 0) == CURRENT_METADATA_VERSION
    if @cached_data_format_is_current
      hash.each do |key, value|
        value = Date.parse(value) if value.is_a?(String) && value =~ /^\d{4}-\d{2}-\d{2}$/
        @metadata[key] = value
      end
    end

    # Even if this is the old format, we want to obey this one tag
    @metadata['no-download'] = hash['no-download'] if hash['no-download']
  end

  def save_metadata
    @metadata['version'] = CURRENT_METADATA_VERSION
    @metadata['date_start_from_last_query'] = @start_date_in_query if @start_date_in_query

    if @download_date_range.nil?
      log "Making up a date range in meta since one wasn't specified. You'll want to change that.", both: true
      today = Date.today
      @download_date_range = (today - 7)..today
    end

    @metadata['earliest_date_start'] = @download_date_range.begin if @metadata['earliest_date_start'].nil?

    @metadata['date_start'] = @download_date_range.begin
    @metadata['date_end'] = @download_date_range.end

    @metadata['jira_url'] = @jira_url

    write_json @metadata, metadata_pathname
  end

  def remove_old_files
    file_prefix = @download_config.project_config.file_prefix
    Dir.foreach @target_path do |file|
      next unless file =~ /^#{file_prefix}_\d+\.json$/

      File.unlink "#{@target_path}#{file}"
    end

    return if @cached_data_format_is_current

    # Also throw away all the previously downloaded issues.
    path = File.join @target_path, "#{file_prefix}_issues"
    return unless File.exist? path

    Dir.foreach path do |file|
      next unless file =~ /\.json$/

      File.unlink File.join(path, file)
    end
  end

  def make_jql filter_id:, today: Date.today
    segments = []
    segments << "filter=#{filter_id}"

    unless @download_config.rolling_date_count.nil?
      @download_date_range = (today.to_date - @download_config.rolling_date_count)..today.to_date

      # For an incremental download, we want to query from the end of the previous one, not from the
      # beginning of the full range.
      @start_date_in_query = metadata['date_end'] || @download_date_range.begin
      log "    Incremental download only. Pulling from #{@start_date_in_query}", both: true if metadata['date_end']

      # Catch-all to pick up anything that's been around since before the range started but hasn't
      # had an update during the range.
      catch_all = '((status changed OR Sprint is not EMPTY) AND statusCategory != Done)'

      # Pick up any issues that had a status change in the range
      start_date_text = @start_date_in_query.strftime '%Y-%m-%d'
      end_date_text = today.strftime '%Y-%m-%d'
      # find_in_range = %((status changed DURING ("#{start_date_text} 00:00","#{end_date_text} 23:59")))
      find_in_range = %((updated >= "#{start_date_text} 00:00" AND updated <= "#{end_date_text} 23:59"))

      segments << "(#{find_in_range} OR #{catch_all})"
    end

    segments.join ' AND '
  end
end
