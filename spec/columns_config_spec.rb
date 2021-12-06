# frozen_string_literal: true

require './spec/spec_helper'

describe ColumnsConfig do
  context 'run' do
    it 'should execute the original block that had been passed in, in its own context' do
      columns = ColumnsConfig.new file_config: nil, block: ->(_) { self.class.to_s }
      expect(columns.run).to eq('ColumnsConfig')
    end
  end

  context 'simple columns' do
    it 'should handle string types' do
      config = ColumnsConfig.new file_config: nil, block: nil
      config.string('foo', ->(issue) { "string:#{issue}" })
      actual = config.columns.collect { |type, name, proc| [type, name, proc.call(1)] }
      expect(actual).to eq [[:string, 'foo', 'string:1']]
    end

    it 'should handle date types' do
      config = ColumnsConfig.new file_config: nil, block: nil
      config.date('foo', ->(issue) { "date:#{issue}" })
      actual = config.columns.collect { |type, name, proc| [type, name, proc.call(1)] }
      expect(actual).to eq [[:date, 'foo', 'date:1']]
    end
  end

  context 'column_entry_times' do
    it 'should fail if no board id set and there are no boards' do
      project_config = ProjectConfig.new exporter: nil, target_path: nil, jira_config: nil, block: nil
      file_config = FileConfig.new project_config: project_config, block: nil
      config = ColumnsConfig.new file_config: file_config, block: nil

      expect { config.column_entry_times }.to raise_error %r{we couldn't find any configuration files}
    end

    it 'should fail if no board id set and there are multiple boards' do
      project_config = ProjectConfig.new exporter: nil, target_path: nil, jira_config: nil, block: nil
      project_config.load_board_configuration(board_id: 2, filename: 'spec/testdata/sample_board_1_configuration.json')
      project_config.load_board_configuration(board_id: 3, filename: 'spec/testdata/sample_board_1_configuration.json')

      file_config = FileConfig.new project_config: project_config, block: nil
      config = ColumnsConfig.new file_config: file_config, block: nil

      expect { config.column_entry_times }.to raise_error %r{following board ids and this is ambiguous}
    end

    it 'should succeed' do
      project_config = ProjectConfig.new exporter: nil, target_path: nil, jira_config: nil, block: nil
      project_config.load_board_configuration(board_id: 1, filename: 'spec/testdata/sample_board_1_configuration.json')
      file_config = FileConfig.new project_config: project_config, block: nil
      columns_config = ColumnsConfig.new file_config: file_config, block: nil
      columns_config.column_entry_times
      actual = columns_config.columns.collect { |type, name, _proc| [type, name] }
      expect(actual).to eq [
        [:date, 'Backlog'],
        [:date, 'Ready'],
        [:date, 'In Progress'],
        [:date, 'Review'],
        [:date, 'Done']
      ]
    end
  end
end
