require 'jirametrics/examples/standard_project'

Exporter.configure do
  timezone_offset '-05:00'

  target_path 'target/'
  jira_config 'jira_config.json'

  standard_project name: 'T-Rex Support', file_prefix: 'T-Rex_support', boards: { 24719 => :default }
  standard_project name: 'T-Rex No Support', file_prefix: 'T-Rex_no_support', boards: { 24721 => :default }
  standard_project name: 'T-Rex', file_prefix: 'T-Rex', boards: { 18969 => :default }

  standard_project name: 'Avngers', file_prefix: 'Avngers', boards: { 22392 => :default }

  standard_project name: 'Mabini', file_prefix: 'Mabini', boards: { 23086 => :default }

end

