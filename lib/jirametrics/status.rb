# frozen_string_literal: true

class Status
  attr_reader :id, :type, :category_name, :category_id, :project_id
  attr_accessor :name

  def initialize name: nil, id: nil, category_name: nil, category_id: nil, project_id: nil, raw: nil
    @name = name
    @id = id
    @category_name = category_name
    @category_id = category_id
    @project_id = project_id

    if raw
      @raw = raw
      @name = raw['name']
      @id = raw['id'].to_i

      category_config = raw['statusCategory']
      @category_name = category_config['name']
      @category_id = category_config['id'].to_i

      # If this is a NextGen project then this status may be project specific. When this field is
      # nil then the status is global.
      @project_id = raw['scope']&.[]('project')&.[]('id')
    end

  end

  def to_s
    "Status(name=#{@name.inspect}, id=#{@id.inspect}," \
      " category_name=#{@category_name.inspect}, category_id=#{@category_id.inspect}, project_id=#{@project_id})"
  end

  def eql?(other)
    (other.class == self.class) && (other.state == state)
  end

  def state
    instance_variables
      .reject {|variable| variable == :@raw}
      .map { |variable| instance_variable_get variable }
  end
end
