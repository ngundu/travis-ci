require 'spec_helper'

RSpec::Matchers.define :be_listed do |repository|
  match do
    # TODO gotta convert to steak to access multiple controllers
    # get 'repositories#index', :format => :json
    # json_reponse.should include(blah)
    true
  end
end

module TestHelpers
  module Walkthrough
    class Worker
      def initialize(context)
        @context = context
      end

      def start!(task)
        task.start! # TODO should PUT to builds/1
        task.reload
      end

      def log!(task, data)
        task.append_log!(data)
        task.reload
      end

      def finish!(task, params)
        task.finish!(params) # TODO should PUT to builds/1
        task.reload
      end
    end

    def ping_from_github!
      authorize 'test', 'test'
      # HOW TO FUCKING HTTP AUTH WITH THIS PIECE OF SHIT OF A LIBRARY.
      post '/builds', :payload => JSON.parse(GITHUB_PAYLOADS['gem-release'])
      @task = Request.first.task
    end

    def credentials
    end

    def next_task!
      # Task::Test.where(:state => 'created').first # TODO bug in simple_states?
      Task::Test.where(:state => nil).first.tap { |task| @task = task if task }
    end

    def worker
      @worker ||= Worker.new(self)
    end

    def task
      @task
    end

    def repository
      _request.repository
    end

    def _request
      task.is_a?(Task::Configure) ? task.owner : task.owner.request
    end

    def build
      task.is_a?(Task::Configure) ? _request.builds.first : task.owner
    end
  end
end

feature 'The build process' do
# describe BuildsController, :type => :controller do
  include TestHelpers::GithubApi, TestHelpers::Walkthrough, TestHelpers::Redis

  before(:each) do
    # TODO extract stub_pusher or something
    Travis.config.notifications = [:worker, :pusher]
    Travis::Notifications::Pusher.any_instance.stubs(:channel).returns(pusher)
    mock_github_api
  end

  let(:pusher) { TestHelpers::Mocks::Pusher.new }
  include Rack::Test::Methods

  scenario 'creates a request from a github payload, configures it, creates the build and runs the tests', :driver => :rack_test do
    # request.env['HTTP_AUTHORIZATION'] = credentials
    p self.class.name
    p respond_to?(:authorize)
    p respond_to?(:basic_authorize)
    ping_from_github!

    _request.should be_created
    pusher.should have_message('build:queued')           # for client compat. should be task:configure:created
    task.should be_queued

    worker.start!(task)
    pusher.should have_message('task:configure:started') # not currently used.

    worker.finish!(task, :config => {})

    _request.should be_finished
    build.should be_created
    pusher.should have_message('task:configure:finished') # not currently used.

    task.should_not be_queued
    # build.matrix.each { |task| task.should be_queued }
    # repository.should_not be_listed

    while next_task!
      worker.start!(task)

      task.should be_started
      build.should be_started
      pusher.should have_message('build:started')

      repository.should be_listed(:status => 'started')
      # build.should show(:status => 'started')
      # task.should show(:status => 'started')

      worker.log!(task, 'foo')
      task.log.should == 'foo'
      pusher.should have_message('build:log', :log => 'foo')

      worker.finish!(task, :status => 0, :log => 'foo bar')
      task.should be_finished
      pusher.should have_message('task:test:finished')   # not currently used.
      # task.should show(:status => 'finished')
    end

    build.should be_finished
    pusher.should have_message('build:finished')
    repository.should be_listed(:status => 'finished')
    # build.should show(:status => 'finished', :log => 'foo bar')
  end
end
