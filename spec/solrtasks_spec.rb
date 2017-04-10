require 'spec_helper'
require 'solrtasks'

describe SolrTasks do
  it 'has a version number' do
    expect(SolrTasks::VERSION).not_to be nil
  end

  it 'autoloads Schema' do
    begin
        SolrTasks::Schema.new({},'dummy')
    rescue
        expect(false).to eq(true), "Encountered exception trying to autoload Schema"
    end
  end

end
