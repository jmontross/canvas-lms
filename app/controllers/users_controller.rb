#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# @API Users
# API for accessing information on the current and other users.
#
# Throughout this API, the `:user_id` parameter can be replaced with `self` as
# a shortcut for the id of the user accessing the API. For instance,
# `users/:user_id/page_views` can be accessed as `users/self/page_views` to
# access the current user's page views.
require 'cgi'
require 'time'
require 'hmac'
require 'hmac-sha2'
require 'base64'

require 'net/http'
require 'uri'
require 'yaml'

class AWSCred
  attr_reader :secret_key, :access_key
  def initialize
    credentials = YAML::load File.read "#{ENV["HOME"]}/.aws"
    #inside $HOME/.aws
    #ACCESSKEY: "YOURACCESSKEY"
    #SECRETKEY: "YOURSECRETKEY"
    @access_key = credentials["ACCESSKEY"]
    @secret_key = credentials["SECRETKEY"]
  end
end




class SnsMessage
  creds = AWSCred.new
  ACCESSKEY = creds.access_key || ENV['AMAZON_ACCESS_KEY_ID'] 
  SECRETKEY = creds.secret_key || ENV['AMAZON_SECRET_ACCESS_KEY']
  puts "ACCESSKEY" + ACCESSKEY.to_s
  AMAZONEP  = 'http://sns.us-east-1.amazonaws.com/'

  def initialize(options)
    @options = options
    self.doMessage
  end
  
  def doMessage 
    sns_signer = AwsSNSMessageSign.new(:access_key => ACCESSKEY, :secret_key => SECRETKEY)
    params = {
      "Action" => "Publish",
      "Message" => @options[:message],
      "Subject" => @options[:subject],
      "TopicArn" => @options[:topic],
    }
    query_string = sns_signer.query_with_signature( params )
    #puts query_string   
    url = URI.parse(AMAZONEP)
    res = Net::HTTP.start(url.host, url.port) {|http|
      http.get('/?' + query_string)
    }    
    puts res.body
  end
end
#SnsMessage.new({:message => 'test', :subject=> 'test', :topic => 'arn:aws:sns:us-east-1:145793127503:ECI_SNS'})


class AwsSNSMessageSign  
  
  def initialize(options = {})
    @secret_key = options[:secret_key]
    raise Exception.new("You must supply a :secret_key") unless @secret_key
    @access_key = options[:access_key]
  end
 
  def query_with_signature(hash)
    return hash_to_query( add_signature(hash)  )
  end
  
  # Pass in a hash representing params for a query string.  
  # param keys should be strings, not symbols please.
  # Will return a param with the "Signature" key/value added, without
  # modifying original. 
  def add_signature(params)
    # Make a copy to not modify original  
    add_signature!( Hash[params]  )
  end
  
  # Like #add_signature, but will mutate the hash passed in, 
  # adding a "Signature" key/value to hash passed in, and return
  # hash too.  
  def add_signature!(params)
    
    # supply timestamp, signature method, signature version and access key if not already provided
    params["Timestamp"] ||= Time.now.iso8601
    #iso8601 is allowed by requiring that gem abotu time up top
    params["AWSAccessKeyId"] ||= access_key
    params["SignatureMethod"] ||= "HmacSHA256"
    params["SignatureVersion"] ||= "2"
    # Existing "Signature"? That's gotta go before we generate a new
    # signature and add it. 
    params.delete("Signature")
 
    query_string = canonical_querystring(params)
 
    string_to_sign = string_to_sign(query_string)
 
    hmac = HMAC::SHA256.new( secret_key )
    hmac.update( string_to_sign )
    # chomp is important!  the base64 encoded version will have a newline at the end
    signature = Base64.encode64(hmac.digest).chomp 
 
    params["Signature"] = signature
 
    #order doesn't matter for the actual request, we return the hash
    #and let client turn it into a url.
    return params
  end
 
  # Insist on specific method of URL encoding, RFC3986. 
  def url_encode(string)
    # It's kinda like CGI.escape, except CGI.escape is encoding a tilde when
    # it ought not to be, so we turn it back. Also space NEEDS to be %20 not +.
    return CGI.escape(string).gsub("%7E", "~").gsub("+", "%20")
  end
 
  # param keys should be strings, not symbols please. return a string joined
  # by & in canonical order. 
  def canonical_querystring(params)
    # I hope this built-in sort sorts by byte order, that's what's required. 
    values = params.keys.sort.collect {|key|  [url_encode(key), url_encode(params[key].to_s)].join("=") }
    
    return values.join("&")
  end
 
  def string_to_sign(query_string, options = {})
    options[:verb] = "GET"
    options[:request_uri] = "/"
    options[:host] = "sns.us-east-1.amazonaws.com"
 
    
    return options[:verb] + "\n" + 
        options[:host].downcase + "\n" +
        options[:request_uri] + "\n" +
        query_string
  end
 
  # Turns a hash into a query string, returns the query string.
  # url-encodes everything to Amazon's specifications. 
  def hash_to_query(hash)
    hash.collect do |key, value|
      
      url_encode(key) + "=" + url_encode(value)
    
    end.join("&")
  end
 
  def secret_key
    return @secret_key
  end
  def access_key
    return @access_key
  end
  def access_key=(a)
    @access_key = a
  end
  
end
## END CRAZY SNS HACK

class UsersController < ApplicationController
  include GoogleDocs
  include Twitter
  include LinkedIn
  include DeliciousDiigo
  before_filter :require_user, :only => [:grades, :delete_user_service, :create_user_service, :confirm_merge, :merge, :kaltura_session, :ignore_channel, :ignore_item, :close_notification, :mark_avatar_image, :user_dashboard, :masquerade]
  before_filter :require_open_registration, :only => [:new, :create]
  
  def oauth
    if !feature_and_service_enabled?(params[:service])
      if params[:service]
        flash[:error] = t('named_service_not_enabled', "The service \"%{name_of_service}\" has not been enabled", :name_of_service => params[:service])
      else
        flash[:error] = t('service_not_enabled', "That service has not been enabled")
      end
      return
    end
    if params[:service] == "google_docs"
      session[:google_docs_authorization_return_to] = params[:return_to] || dashboard_url(:only_path => false)
      redirect_to google_docs_request_token_url(session[:google_docs_authorization_return_to])
    elsif params[:service] == "twitter"
      session[:twitter_authorization_return_to] = params[:return_to] || dashboard_url(:only_path => false)
      redirect_to twitter_request_token_url(session[:twitter_authorization_return_to])
    elsif params[:service] == "linked_in"
      session[:linked_in_authorization_return_to] = params[:return_to] || dashboard_url(:only_path => false)
      redirect_to linked_in_request_token_url(session[:linked_in_authorization_return_to])
    elsif params[:service] == "facebook"
      oauth_request = OauthRequest.create(
        :service => 'facebook',
        :secret => AutoHandle.generate("fb", 10),
        :return_url => params[:return_to],
        :user => @current_user,
        :original_host_with_port => request.host_with_port
      )
      redirect_to Facebook.authorize_url(oauth_request)
    end
  end
  
  def grades
    @user = User.find_by_id(params[:user_id]) if params[:user_id].present?
    @user ||= @current_user
    if authorized_action(@user, @current_user, :read)
      @current_active_enrollments = @user.current_enrollments.scoped(:include => :course)
      @prior_enrollments = []; @current_enrollments = []
      @current_active_enrollments.each do |e|
        case e.state_based_on_date
        when :active
          @current_enrollments << e
        when :completed
          #@prior_enrollments << e
        end
      end
      #@prior_enrollments.concat @user.concluded_enrollments.select{|e| e.is_a?(StudentEnrollment) }

      @student_enrollments = @current_enrollments.select{|e| e.is_a?(StudentEnrollment) }
      
      @observer_enrollments = @current_enrollments.select{|e| e.is_a?(ObserverEnrollment) && e.associated_user_id }
      @observed_enrollments = []
      @observer_enrollments.each do |e|
        @observed_enrollments << StudentEnrollment.active.find_by_user_id_and_course_id(e.associated_user_id, e.course_id)
      end
      @observed_enrollments = @observed_enrollments.uniq.compact

      if @current_enrollments.length + @observed_enrollments.length == 1# && @prior_enrollments.empty?
        redirect_to course_grades_url(@current_enrollments.first.course_id)
        return
      end
      Enrollment.send(:preload_associations, @observed_enrollments, :course)

      @teacher_enrollments = @current_enrollments.select{|e| e.admin? }
      #Enrollment.send(:preload_associations, @prior_enrollments, :course)
      @course_grade_summaries = {}
      @teacher_enrollments.each do |enrollment|
        @course_grade_summaries[enrollment.course_id] = Rails.cache.fetch(['computed_avg_grade_for', enrollment.course].cache_key) do
          goodies = enrollment.course.student_enrollments.map(&:computed_current_score).compact
          score = (goodies.sum.to_f * 100.0 / goodies.length.to_f).round.to_f / 100.0 rescue nil
          {:score => score, :students => goodies.length }
        end
      end
    end
  end
  
  def oauth_success
    oauth_request = nil
    if params[:oauth_token]
      oauth_request = OauthRequest.find_by_token_and_service(params[:oauth_token], params[:service])
    elsif params[:state] && params[:service] == 'facebook'
      oauth_request = OauthRequest.find_by_id(Facebook.oauth_request_id(params[:state]))
    end
    
    if !oauth_request || (request.host_with_port == oauth_request.original_host_with_port && oauth_request.user != @current_user)
      flash[:error] = t('oauth_fail', "OAuth Request failed. Couldn't find valid request")
      redirect_to (@current_user ? profile_url : root_url)
    elsif request.host_with_port != oauth_request.original_host_with_port
      url = url_for request.parameters.merge(:host => oauth_request.original_host_with_port, :only_path => false)
      redirect_to url
    else
      if params[:service] == "facebook"
        service = Facebook.authorize_success(@current_user, params[:access_token])
        if service
          flash[:notice] = t('facebook_added', "Facebook account successfully added!")
        else
          flash[:error] = t('facebook_fail', "Facebook authorization failed.")
        end
        return_to(oauth_request.return_url, profile_url)
      elsif params[:service] == "google_docs"
        begin
          google_docs_get_access_token(oauth_request)
          doc_list = google_doc_list
          flash[:notice] = t('google_docs_added', "Google Docs access authorized!")
        rescue => e
          flash[:error] = t('google_docs_fail', "Google Docs authorization failed. Please try again")
        end
        return_to(session[:google_docs_authorization_return_to], profile_url)
      elsif params[:service] == "linked_in"
        begin
          linked_in_get_access_token(oauth_request)
          flash[:notice] = t('linkedin_added', "LinkedIn account successfully added!")
        rescue => e
          flash[:error] = t('linkedin_fail', "LinkedIn authorization failed. Please try again")
        end
        return_to(session[:linked_in_authorization_return_to], profile_url)
      else
        begin
          token = twitter_get_access_token(oauth_request)
          favorites = twitter_list(token)
          flash[:notice] = t('twitter_added', "Twitter access authorized!")
        rescue => e
          flash[:error] = t('twitter_fail_whale', "Twitter authorization failed. Please try again")
        end
        return_to(session[:twitter_authorization_return_to], profile_url)
      end
    end
  end
  
  def ignore_channel
    @current_pseudonym.update_attribute(:login_path_to_ignore, params[:path])
    session[:conflict_channel] = nil
    flash[:notice] = t('remove_warning', "You'll no longer receive warnings about the address %{email} from this login", :email => params[:path])
    redirect_to dashboard_url
  end
  
  def index
    get_context
    if authorized_action(@context, @current_user, :read_roster)
      @root_account = @context.root_account || @account
      @users = []
      @query = (params[:user] && params[:user][:name]) || params[:term]
      if @context && @context.is_a?(Account) && @query
        @users = @context.users_name_like(@query)
      elsif params[:enrollment_term_id].present? && @root_account == @context
        @users = @context.fast_all_users.scoped(:joins => :courses, :conditions => ["courses.enrollment_term_id = ?", params[:enrollment_term_id]], :group => 'users.id, users.name, users.sortable_name')
      else
        @users = @context.fast_all_users
      end
      @users = @users.paginate(:page => params[:page], :per_page => @per_page, :total_entries => @users.size)
      respond_to do |format|
        if @users.length == 1 && params[:term]
          format.html {
            redirect_to(named_context_url(@context, :context_user_url, @users.first))
          }
        else
          @enrollment_terms = []
          if @root_account == @context
            @enrollment_terms = @context.enrollment_terms.active
          end
          format.html
        end
        format.json  {
          cancel_cache_buster
          expires_in 30.minutes 
          render :json => @users.map{ |u| {:label => u.name, :id => u.id} }
        }
      end
    end
  end

  def masquerade
    @user = User.find_by_id(params[:user_id])
    if (authorized_action(@user, @real_current_user || @current_user, :become_user))
      if request.post?
        if @user == @real_current_user
          session[:become_user_id] = nil
        else
          session[:become_user_id] = params[:user_id]
        end
        return_url = session[:masquerade_return_to]
        session[:masquerade_return_to] = nil
        return return_to(return_url, request.referer)
      end
    end
  end

  def user_dashboard
    get_context
    puts "at user dashboard!!"
    puts "the api : #{@API.inspect}"
    puts " about to do an sns message... need sis_user_id "
    puts "#{SnsMessage.new({:message => {
        :Name => "Canvas.Student.login",
        :Type => "UI", 
        :Body => { :sis_user_id => "jmontross@empowered.com" },
        :Sequence => "1",
        :EventTimestamp => "#{Time.now.iso8601}"
        }.to_json, :subject=> 'test', :topic => 'arn:aws:sns:us-east-1:145793127503:ECI_SNS'})}"
    puts "just posted to my fake eci_sns"

     puts "#{SnsMessage.new({:message => {
        :Name => "Canvas.Student.login",
        :Type => "UI", 
        :Body => { :sis_user_id => "jmontross@empowered.com" },
        :Sequence => "1",
        :EventTimestamp => "#{Time.now.iso8601}"
        }.to_json, :subject=> 'test', :topic => 'arn:aws:sns:us-east-1:145793127503:empowered_events'})}"
    
    puts "just posted to empowered_events"

   
   # puts " is the id unique_id? #{unique_id} "  This breaks,,, unique_id doesn't friggin work.

    # dont show crubms on dashboard because it does not make sense to have a breadcrumb
    # trail back to home if you are already home
    clear_crumbs 
    
    if request.path =~ %r{\A/dashboard\z}
      return redirect_to(dashboard_url, :status => :moved_permanently)
    end
    disable_page_views if @current_pseudonym && @current_pseudonym.unique_id == "pingdom@instructure.com"
    if @show_recent_feedback = (@current_user.student_enrollments.active.size > 0)
      @recent_feedback = (@current_user && @current_user.recent_feedback) || []
    end
    @account_notifications = AccountNotification.for_user_and_account(@current_user, @domain_root_account)
    @is_default_account = @current_user.pseudonyms.active.map(&:account_id).include?(Account.default.id)
  end

  include Api::V1::StreamItem

  # @API
  # Returns the current user's global activity stream.
  #
  # The response is currently hard-coded to the last 2 weeks or 21 total items.
  #
  # There are many types of objects that can be returned in the activity
  # stream. All object types have the same basic set of shared attributes:
  #   {
  #     'created_at': '2011-07-13T09:12:00Z',
  #     'updated_at': '2011-07-25T08:52:41Z',
  #     'id': 1234,
  #     'title': 'Stream Item Subject',
  #     'message': 'This is the body text of the activity stream item. It is plain-text, and can be multiple paragraphs.',
  #     'type': 'DiscussionTopic|Conversation|Message|Submission|Conference|Collaboration|...',
  #     'context_type': 'course', // course|group
  #     'course_id': 1,
  #     'group_id': null,
  #   }
  #
  # In addition, each item type has its own set of attributes available.
  #
  # DiscussionTopic:
  #
  #   {
  #     'type': 'DiscussionTopic',
  #     'discussion_topic_id': 1234,
  #     'total_root_discussion_entries': 5,
  #     'root_discussion_entries': {
  #       ...
  #     }
  #   }
  # For DiscussionTopic, the message is truncated at 4kb.
  #
  # Announcement:
  #
  #   {
  #     'type': 'Announcement',
  #     'announcement_id': 1234,
  #     'total_root_discussion_entries': 5,
  #     'root_discussion_entries': {
  #       ...
  #     }
  #   }
  # For Announcement, the message is truncated at 4kb.
  #
  # Conversation:
  #
  #   {
  #     'type': 'Conversation',
  #     'conversation_id': 1234,
  #     'private': false,
  #     'participant_count': 3,
  #   }
  #
  # Message:
  #
  #   {
  #     'type': 'Message',
  #     'message_id': 1234,
  #     'notification_category': 'Assignment Graded'
  #   }
  #
  # Submission:
  #
  #   {
  #     'type': 'Submission',
  #     'grade': '12',
  #     'score': 12,
  #     'assignment': {
  #       'title': 'Assignment 3',
  #       'id': 5678,
  #       'points_possible': 15
  #     }
  #   }
  #
  # Conference:
  #
  #   {
  #     'type': 'Conference',
  #     'web_conference_id': 1234
  #   }
  #
  # Collaboration:
  #
  #   {
  #     'type': 'Collaboration',
  #     'collaboration_id': 1234
  #   }
  def activity_stream
    if @current_user
      render :json => @current_user.stream_items.map { |i| stream_item_json(i) }
    else
      render_unauthorized_action
    end
  end

  def manageable_courses
    get_context
    if authorized_action(@context, @current_user, :manage)
      @courses = []
      @query = (params[:course] && params[:course][:name]) || params[:term]
      @courses = @context.manageable_courses_name_like(@query) if @context && @query
      respond_to do |format|
        format.json  {
          cancel_cache_buster
          expires_in 30.minutes 
          render :json => @courses.map{ |c| {:label => c.name, :id => c.id} }
        }
      end
    end
  end

  include Api::V1::TodoItem
  # @API
  # Returns the current user's list of todo items, as seen on the user dashboard.
  #
  # There is a limit to the number of items returned.
  #
  # The `ignore` and `ignore_permanently` URLs can be used to update the user's
  # preferences on what items will be displayed.
  # Performing a DELETE request against the `ignore` URL will hide that item
  # from future todo item requests, until the item changes.
  # Performing a DELETE request against the `ignore_permanently` URL will hide
  # that item forever.
  #
  # @example_response
  #   [
  #     {
  #       'type': 'grading',        // an assignment that needs grading
  #       'assignment': { .. assignment object .. },
  #       'ignore': '.. url ..',
  #       'ignore_permanently': '.. url ..',
  #       'needs_grading_count': 3, // number of submissions that need grading
  #       'context_type': 'course', // course|group
  #       'course_id': 1,
  #       'group_id': null,
  #     },
  #     {
  #       'type' => 'submitting',   // an assignment that needs submitting soon
  #       'assignment' => { .. assignment object .. },
  #       'ignore' => '.. url ..',
  #       'ignore_permanently' => '.. url ..',
  #       'context_type': 'course',
  #       'course_id': 1,
  #     }
  #   ]
  def todo_items
    unless @current_user
      return render_unauthorized_action
    end

    grading = @current_user.assignments_needing_grading().map { |a| todo_item_json(a, 'grading') }
    submitting = @current_user.assignments_needing_submitting().map { |a| todo_item_json(a, 'submitting') }
    render :json => (grading + submitting)
  end

  def ignore_item
    unless %w[grading submitting].include?(params[:purpose])
      return render(:json => { :ignored => false }, :status => 400)
    end
    @current_user.ignore_item!(params[:asset_string], params[:purpose], params[:permanent] == '1')
    render :json => { :ignored => true }
  end

  def ignore_stream_item
    StreamItemInstance.update_all({ :hidden => true }, { :stream_item_id => params[:id], :user_id => @current_user.id })
    render :json => { :hidden => true }
  end
  
  def close_notification
    @current_user.close_notification(params[:id])
    render :json => @current_user.to_json
  end
  
  def delete_user_service
    @current_user.user_services.find(params[:id]).destroy
    render :json => {:deleted => true}
  end
  
  def create_user_service
    begin
      user_name = params[:user_service][:user_name]
      password = params[:user_service][:password]
      service = OpenObject.new(:service_user_name => user_name, :decrypted_password => password)
      case params[:user_service][:service]
        when 'delicious'
          delicious_get_last_posted(service)
        when 'diigo'
          diigo_get_bookmarks(service, 1)
        when 'skype'
          true
        else
          raise "Unknown Service"
      end
      @service = UserService.register_from_params(@current_user, params[:user_service])
      render :json => @service.to_json
    rescue => e
      render :json => {:errors => true}, :status => :bad_request
    end
  end
  
  def services
    params[:service_types] ||= params[:service_type]
    json = Rails.cache.fetch(['user_services', @current_user, params[:service_type]].cache_key) do
      @services = @current_user.user_services rescue []
      if params[:service_types]
        @services = @services.of_type(params[:service_types].split(",")) rescue []
      end
      @services.to_json(:only => [:service_user_id, :service_user_url, :service_user_name, :service, :type, :id])
    end
    render :json => json
  end
  
  def bookmark_search
    @service = @current_user.user_services.find_by_type_and_service('BookmarkService', params[:service_type]) rescue nil
    res = nil
    res = @service.find_bookmarks(params[:q]) if @service
    render :json => res.to_json
  end
  
  def image_search
    @service = ImageService.new(:service => "flickr")
    res = @service.find_images(params[:q])
    render :json => res.to_json
  end
  
  def show
    get_context
    @context_account = @context.is_a?(Account) ? @context : @domain_root_account
    @user = params[:id] ? User.find(params[:id]) : @current_user
    if current_user_is_site_admin? || authorized_action(@user, @current_user, :view_statistics)
      add_crumb(t('crumbs.profile', "%{user}'s profile", :user => @user.short_name), @user == @current_user ? profile_path : user_path(@user) )
      @page_views = @user.page_views.paginate :page => params[:page], :order => 'created_at DESC', :per_page => 50

      # course_section and enrollment term will only be used if the enrollment dates haven't been cached yet;
      # maybe should just look at the first enrollment and check if it's cached to decide if we should include
      # them here
      @enrollments = @user.enrollments.scoped(:conditions => "workflow_state<>'deleted'", :include => [{:course => { :enrollment_term => :enrollment_dates_overrides }}, :associated_user, :course_section]).select{|e| e.course && !e.course.deleted? }.sort_by{|e| [e.state_sortable, e.rank_sortable, e.course.name] }
      # pre-populate the reverse association
      @enrollments.each { |e| e.user = @user }
      @group_memberships = @user.group_memberships.scoped(:include => :group)

      respond_to do |format|
        format.html
      end
    end
  end
  
  def new
    @user = User.new
    @pseudonym = @current_user ? @current_user.pseudonyms.build(:account => @domain_root_account) : Pseudonym.new(:account => @domain_root_account)
    render :action => "new"
  end

  def create
    @pseudonym = Pseudonym.find_by_unique_id_and_account_id(params[:pseudonym][:unique_id], @domain_root_account.id)
    @pseudonym ||= Pseudonym.new(:unique_id => params[:pseudonym][:unique_id], :account => @domain_root_account)
    @pseudonym.save_without_session_maintenance if @pseudonym.new_record?
    @active_cc = CommunicationChannel.find_by_path_and_path_type_and_workflow_state(params[:pseudonym][:unique_id], 'email', 'active')
    @any_cc = CommunicationChannel.find_by_path_and_path_type(params[:pseudonym][:unique_id], 'email') unless @active_cc
    # If a teacher created the student, and the student then comes to register, they
    # should still be allowed to.
    if @active_cc && @active_cc.user && !@pseudonym.user
      @user ||= @active_cc.user
    elsif @any_cc && @any_cc.user && !@pseudonym.user
      @user ||= @any_cc.user
    elsif @pseudonym && (!@pseudonym.user || @pseudonym.user.creation_pending?)
      @user ||= @pseudonym.user
    else
      # If not creation_pending, we want to throw an already_exists error, which
      # we'll get if we set this to nil, since then a few lines down will try to
      # create a new pseudonym with the same id.
      @pseudonym = nil
    end
    @user ||= User.new
    @user.attributes = params[:user]
    @user.name ||= params[:pseudonym][:unique_id]
    if @user.errors.empty? && @user.save
      @pseudonym ||= @user.pseudonyms.build
      @pseudonym.attributes = params[:pseudonym]
      @pseudonym.account_id = @domain_root_account.id
      @pseudonym.user = @user
      @pseudonym.workflow_state = 'active'
      @pseudonym.path = params[:pseudonym][:unique_id]
      @pseudonym.errors.clear
      if @pseudonym.new_record? && CommunicationChannel.find_by_path_and_workflow_state(@pseudonym.unique_id, 'active')
        @pseudonym.errors.add(:unique_id, t('login_taken', "That login has already been taken"))
      end
      if @pseudonym.valid?
        @pseudonym.save_without_session_maintenance
        @pseudonym.assert_communication_channel(true)
        @user.reload
        
        if @user.registration_approval_required? && params[:new_teacher]
          @user.workflow_state = 'pending_approval'
          @user.save
        else
          @user.workflow_state = 'pre_registered'
          @user.save
          @pseudonym.send_confirmation!
        end
        @user.new_teacher_registration((params[:user] || {}).merge({:remote_ip  => request.remote_ip})) if params[:new_teacher]
        
        data = OpenObject.new(:user => @user, :pseudonym => @pseudonym, :channel => @pseudonym.communication_channel)
        respond_to do |format|
          flash[:user_id] = @user.id
          flash[:pseudonym_id] = @pseudonym.id
          format.html { redirect_to registered_url }
          format.json { render :json => data.to_json }
        end
      else
        # User can't exist without pseudonyms, since there'd be no way to log in or contact
        @user.reload
        @user.destroy if @user.pseudonyms.select{|p| !p.new_record? }.empty?
        render :action => :new
      end
    else
      render :action => :new
    end
  end
  
  def registered
    @pseudonym_session.destroy if @pseudonym_session
    @pseudonym = Pseudonym.find_by_id(flash[:pseudonym_id]) if flash[:pseudonym_id].present?
    if flash[:user_id] && (@user = User.find(flash[:user_id]))
      @email_address = @pseudonym && @pseudonym.communication_channel && @pseudonym.communication_channel.path
      @email_address ||= @user.email
      @pseudonym ||= @user.pseudonym
      @cc = @pseudonym.communication_channel || @user.communication_channel
      render :action => "registered"
    else
      redirect_to root_url
    end
  end
  
  def update
    @user = params[:id] ? User.find(params[:id]) : @current_user
    rename = params[:rename]
    if (!rename ? authorized_action(@user, @current_user, :manage) : authorized_action(@user, @current_user, :rename))
      if rename
        params[:default_pseudonym_id] = nil
        managed_attributes = [:name, :short_name]
        managed_attributes << :time_zone if @user.grants_right?(@current_user, nil, :manage_user_details)
        params[:user] = params[:user].slice(*managed_attributes)
      end
      if params[:default_pseudonym_id] && @user == @current_user
        @default_pseudonym = @user.pseudonyms.find(params[:default_pseudonym_id])
        @default_pseudonym.move_to_top
      end
      respond_to do |format|
        if @user.update_attributes(params[:user])
          flash[:notice] = t('user_updated', 'User was successfully updated.')
          format.html { redirect_to user_url(@user) }
          format.xml  { head :ok }
          format.json { render :json => @user.to_json(:methods => :default_pseudonym_id) }
        else
          format.html { render :action => "edit" }
          format.xml  { render :xml => @user.errors.to_xml }
        end
      end
    end
  end

  def media_download
    url = Rails.cache.fetch(['media_download_url', params[:entryId], params[:type]].cache_key, :expires_in => 30.minutes) do
      client = Kaltura::ClientV3.new
      client.startSession(Kaltura::SessionType::ADMIN)
      assets = client.flavorAssetGetByEntryId(params[:entryId])
      asset = assets.find {|a| a[:fileExt] == params[:type] }
      if asset
        client.flavorAssetGetDownloadUrl(asset[:id])
      else
        nil
      end
    end
    
    if url
      if params[:redirect] == '1'
        if %w(mp3 mp4).include?(params[:type])
          # hack alert -- iTunes (and maybe others who follow the same podcast
          # spec) requires that the download URL for podcast items end in .mp3
          # or another supported media type. Normally, the Kaltura download URL
          # doesn't end in .mp3. But Kaltura's first download URL redirects to
          # the same download url with /relocate/filename.ext appended, so we're
          # just going to explicitly append that to skip the first redirect, so
          # that iTunes will download the podcast items. This doesn't appear to
          # be documented anywhere though, so we're talking with Kaltura about
          # a more official solution.
          url = "#{url}/relocate/download.#{params[:type]}"
        end
        redirect_to url
      else
        render :json => { 'url' => url }
      end
    else
      render :status => 404, :text => t('could_not_find_url', "Could not find download URL")
    end
  end
  
  def merge
    @user_about_to_go_away = User.find_by_uuid(session[:merge_user_uuid]) if session[:merge_user_uuid].present?
    @user_about_to_go_away = nil unless @user_about_to_go_away.id == params[:user_id].to_i
    
    if params[:new_user_uuid] && @true_user = User.find_by_uuid(params[:new_user_uuid])
      if @true_user.grants_right?(@current_user, session, :manage_logins) && @user_about_to_go_away.grants_right?(@current_user, session, :manage_logins)
        @user_that_will_still_be_around = @true_user
      else
        @user_that_will_still_be_around = nil
      end
    else
      @user_that_will_still_be_around = @current_user
    end

    if @user_about_to_go_away && @user_that_will_still_be_around && @user_about_to_go_away.id.to_s == params[:user_id]
      @user_about_to_go_away.move_to_user(@user_that_will_still_be_around)
      @user_that_will_still_be_around.touch
      session[:merge_user_uuid] = nil
      flash[:notice] = t('user_merge_success', "User merge succeeded! %{first_user} and %{second_user} are now one and the same.", :first_user => @user_that_will_still_be_around.name, :second_user => @user_about_to_go_away.name)
    else
      flash[:error] = t('user_merge_fail', "User merge failed. Please make sure you have proper permission and try again.")
    end
    if @user_that_will_still_be_around == @current_user
      redirect_to profile_url
    elsif @user_that_will_still_be_around
      redirect_to user_url(@user_that_will_still_be_around)
    else
      redirect_to dashboard_url
    end
  end
  
  def admin_merge
    @user = User.find(params[:user_id])
    pending_user_id = params[:pending_user_id] || session[:pending_user_id]
    @pending_other_user = User.find_by_id(pending_user_id) if pending_user_id.present?
    @pending_other_user = nil if @pending_other_user == @user
    @other_user = User.find_by_id(params[:new_user_id]) if params[:new_user_id].present?
    if authorized_action(@user, @current_user, :manage_logins)
      if @user && (params[:clear] || !@pending_other_user)
        session[:pending_user_id] = @user.id
        @pending_other_user = nil
      end
      if @other_user && @other_user.grants_right?(@current_user, session, :manage_logins)
        session[:merge_user_id] = @user.id
        session[:merge_user_uuid] = @user.uuid
        session[:pending_user_id] = nil
      else
        @other_user = nil
      end
      render :action => 'admin_merge'
    end
  end
  
  def confirm_merge
    @user = User.find_by_uuid(session[:merge_user_uuid]) if session[:merge_user_uuid].present?
    @user = nil unless @user && @user.id == session[:merge_user_id]
    if @user && @user != @current_user
      render :action => 'confirm_merge'
    else
      session[:merge_user_uuid] = @current_user.uuid
      session[:merge_user_id] = @current_user.id
      store_location(user_confirm_merge_url(@current_user.id))
      render :action => 'merge'
    end
  end
  
  def assignments_needing_grading
    @user = User.find(params[:user_id])
    if authorized_action(@user, @current_user, :read)
      res = @user.assignments_needing_grading
      render :json => res.to_json
    end
  end
  
  def assignments_needing_submitting
    @user = User.find(params[:user_id])
    if authorized_action(@user, @current_user, :read)
      render :json => @user.assignments_needing_submitting.to_json
    end
  end
  
  def mark_avatar_image
    if params[:remove]
      if authorized_action(@user, @current_user, :remove_avatar)
        @user.avatar_image = {}
        @user.save
        render :json => @user.to_json
      end
    else
      if !session["reported_#{@user.id}".to_sym]
        if params[:context_code]
          @context = Context.find_by_asset_string(params[:context_code]) rescue nil
          @context = nil unless context.respond_to?(:users) && context.users.find_by_id(@user.id)
        end
        @user.report_avatar_image!(@context)
      end
      session["reports_#{@user.id}".to_sym] = true
      render :json => {:reported => true}.to_json
    end
  end

  def delete
    @user = User.find(params[:user_id])
    if authorized_action(@user, @current_user, :manage)
      if @user.pseudonyms.any?{|p| p.managed_password? }
        flash[:notice] = t('no_deleting_sis_user', "You cannot delete a system-generated user")
        redirect_to profile_url
      end
    end
  end

  def destroy
    @user = User.find(params[:id])
    if authorized_action(@user, @current_user, :manage)
      @user.destroy
      if @user == @current_user
        @pseudonym_session.destroy rescue true
        reset_session
      end
      
      respond_to do |format|
        flash[:notice] = t('user_is_deleted', "%{user_name} has been deleted", :user_name => @user.name)
        if @user == @current_user
          format.html { redirect_to root_url }
        else
          format.html { redirect_to(users_url) }
        end
        format.xml  { head :ok }
        format.json { render :json => @user.to_json }
      end
    end
  end

  def report_avatar_image
    @user = User.find(params[:user_id])
    key = "reported_#{@user.id}"
    if !session[key]
      session[key] = true
      @user.report_avatar_image!
    end
    render :json => {:ok => true}
  end
  
  def update_avatar_image
    @user = User.find(params[:user_id])
    if authorized_action(@user, @current_user, :remove_avatar)
      @user.avatar_state = params[:avatar][:state]
      @user.save
      render :json => @user.to_json(:include_root => false)
    end
  end
  
  def public_feed
    return unless get_feed_context(:only => [:user])
    feed = Atom::Feed.new do |f|
      f.title = "#{@context.name} Feed"
      f.links << Atom::Link.new(:href => dashboard_url)
      f.updated = Time.now
      f.id = named_context_url(@context, :context_url)
    end
    @entries = []
    @context.courses.each do |context|
      @entries.concat context.assignments.active
      @entries.concat context.calendar_events.active
      @entries.concat context.discussion_topics.active
      @entries.concat context.default_wiki_wiki_pages.select{|p| !p.deleted? }
    end
    @entries = @entries.select{|e| e.updated_at > 1.weeks.ago }
    @entries.each do |entry|
      feed.entries << entry.to_atom(:include_context => true, :context => @context)
    end
    respond_to do |format|
      format.atom { render :text => feed.to_xml }
    end
  end
  
  def require_open_registration
    if @domain_root_account && !@domain_root_account.settings[:open_registration]
      flash[:error] = t('no_open_registration', "Open registration has not been enabled for this account")
      redirect_to root_url
      return false
    end
  end
  protected :require_open_registration

  def teacher_activity
    @teacher = User.find(params[:user_id])
    if @teacher == @current_user || authorized_action(@teacher, @current_user, :view_statistics)
      @courses = {}

      if params[:student_id]
        student = User.find(params[:student_id])
        enrollments = student.student_enrollments.active.all(:include => :course)
        enrollments.each do |enrollment|
          if enrollment.course.user_is_teacher?(@teacher) && enrollment.course.enrollments_visible_to(@teacher).find_by_id(enrollment.id) && enrollment.course.grants_right?(@current_user, :read_reports)
            @courses[enrollment.course] = teacher_activity_report(@teacher, enrollment.course, [enrollment])
          end
        end

        if @courses.all? { |c, e| e.blank? }
          flash[:error] = t('errors.no_teacher_courses', "There are no courses shared between this teacher and student")
          redirect_to_referrer_or_default(root_url)
        end

      else # implied params[:course_id]
        course = Course.find(params[:course_id])
        if !course.user_is_teacher?(@teacher)
          flash[:error] = t('errors.user_not_teacher', "That user is not a teacher in this course")
          redirect_to_referrer_or_default(root_url)
        elsif authorized_action(course, @current_user, :read_reports)
          @courses[course] = teacher_activity_report(@teacher, course, course.enrollments_visible_to(@teacher))
        end
      end

    end
  end

  protected

  def teacher_activity_report(teacher, course, student_enrollments)
    ids = student_enrollments.map(&:user_id)
    data = {}
    student_enrollments.each { |e| data[e.user.id] = { :enrollment => e, :ungraded => [] } }

    # find last interactions
    last_comment_dates = SubmissionComment.for_context(course).maximum(
      :created_at,
      :group => 'recipient_id',
      :conditions => ["author_id = ? AND recipient_id IN (?)", teacher.id, ids])
    last_comment_dates.each do |user_id, date|
      next unless student = data[user_id]
      student[:last_interaction] = [student[:last_interaction], date].compact.max
    end
    last_message_dates = ConversationMessage.maximum(
      :created_at,
      :joins => 'INNER JOIN conversation_participants ON conversation_participants.conversation_id=conversation_messages.conversation_id',
      :group => ['conversation_participants.user_id', 'conversation_messages.author_id'],
      :conditions => [ 'conversation_messages.author_id = ? AND conversation_participants.user_id IN (?) AND NOT conversation_messages.generated', teacher.id, ids ])
    last_message_dates.each do |key, date|
      next unless student = data[key.first.to_i]
      student[:last_interaction] = [student[:last_interaction], date].compact.max
    end

    # find all ungraded submissions in one query
    ungraded_submissions = course.submissions.all(
      :include => :assignment,
      :conditions => ["user_id IN (?) AND #{Submission.needs_grading_conditions}", ids])
    ungraded_submissions.each do |submission|
      next unless student = data[submission.user_id]
      student[:ungraded] << submission
    end

    if course.root_account.enable_user_notes?
      data.each { |k,v| v[:last_user_note] = nil }
      # find all last user note times in one query
      note_dates = UserNote.active.maximum(
        :created_at,
        :group => 'user_id',
        :conditions => ["created_by_id = ? AND user_id IN (?)", teacher.id, ids])
      note_dates.each do |user_id, date|
        next unless student = data[user_id]
        student[:last_user_note] = date
      end
    end

    data.values.sort_by { |e| e[:enrollment].user.sortable_name }
  end
end
