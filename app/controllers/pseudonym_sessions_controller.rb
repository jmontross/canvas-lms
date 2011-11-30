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

class PseudonymSessionsController < ApplicationController
  protect_from_forgery :except => [:create, :destroy, :saml_consume, :oauth2_token]
  before_filter :forbid_on_files_domain, :except => [ :clear_file_session ]

  def new
    puts "new pseudonym session controller"
    puts "new pseudonym session controller test"
    logger.info "new pseudo on logger"
    if @current_user && !params[:re_login]
      # maybe in here!! 
      puts "at current user and redirecting to dashboard_url..."
      puts params.inspect
      redirect_to dashboard_url
      return
    end

    if params[:needs_cookies] == '1'
      @needs_cookies = true
      return render(:template => 'shared/unauthorized', :layout => 'application', :status => :unauthorized)
    end

    @pseudonym_session = PseudonymSession.new
    @headers = false
    @is_delegated = @domain_root_account.delegated_authentication? && !params[:canvas_login]
    @is_cas = @domain_root_account.cas_authentication? && @is_delegated
    @is_saml = @domain_root_account.saml_authentication? && @is_delegated
    if @is_cas && !params[:no_auto]
      if session[:exit_frame]
        session[:exit_frame] = nil
        render :template => 'shared/exit_frame', :layout => false, :locals => {
          :url => login_url(params)
        }
        return
      elsif params[:ticket]
        # not in here
        # handle the callback from CAS
        logger.info "Attempting CAS login with ticket #{params[:ticket]} in account #{@domain_root_account.id}"
        st = CASClient::ServiceTicket.new(params[:ticket], login_url)
        begin
          cas_client.validate_service_ticket(st)
        rescue => e
          # not in here
          logger.warn "Failed to validate CAS ticket: #{e.inspect}"
          flash[:delegated_message] = t 'errors.login_error', "There was a problem logging in at %{institution}", :institution => @domain_root_account.display_name
          redirect_to login_url(:no_auto=>'true')
          return
        end
        if st.is_valid?
          @pseudonym = nil
          @pseudonym = @domain_root_account.pseudonyms.custom_find_by_unique_id(st.response.user)
          if @pseudonym
            # not in here...
            # Successful login and we have a user
            puts "Successful login and we have a user"
            @domain_root_account.pseudonym_sessions.create!(@pseudonym, false)
            session[:cas_login] = true
            @user = @pseudonym.login_assertions_for_user rescue nil
              
            successful_login(@user, @pseudonym)
            return
          else
            # not in here
            logger.warn "Received CAS login for unknown user: #{st.response.user}"
            reset_session
            session[:delegated_message] = t 'errors.no_matching_user', "Canvas doesn't have an account for user: %{user}", :user => st.response.user
            redirect_to(cas_client.logout_url(login_url :no_auto => true))
            return
          end
        else
          logger.warn "Failed CAS login attempt."
          flash[:delegated_message] = t 'errors.login_error', "There was a problem logging in at %{institution}", :institution => @domain_root_account.display_name
          redirect_to login_url(:no_auto=>'true')
          return
        end
      end
      puts "cas login"
      initiate_cas_login(cas_client)
    elsif @is_saml && !params[:no_auto]
      puts "it's saml and we are logging in!"
      initiate_saml_login(request.env['canvas.account_domain'])
    else
      render :action => "new"
    end
    flash[:delegated_message] = session.delete :delegated_message
  end

  def create
    # reset the session id cookie to prevent session fixation.
    reset_session_for_login

    # Try to use authlogic's built-in login approach first
    @pseudonym_session = @domain_root_account.pseudonym_sessions.new(params[:pseudonym_session])
    found = @pseudonym_session.save
    
    # TODO: don't allow logins from other root accounts anymore
    # If authlogic fails and this account allows handles from other account,
    # try to log in with a handle from another account
    if !found && !@domain_root_account.require_account_pseudonym? && params[:pseudonym_session]
      valid_alternative = Pseudonym.custom_find_by_unique_id(params[:pseudonym_session][:unique_id], :all).find{|p|
        (p.valid_password?(params[:pseudonym_session][:password]) && p.account.password_authentication?) rescue false
      }
      if valid_alternative
        @pseudonym_session = PseudonymSession.new(valid_alternative, params[:pseudonym_session][:remember_me] == "1")
        @pseudonym_session.save
        found = true
      end
    end
    
    @pseudonym = @pseudonym_session && @pseudonym_session.record
    # If the user's account has been deleted, feel free to share that information
    if @pseudonym && (!@pseudonym.user || @pseudonym.user.unavailable?)
      flash[:error] = t 'errors.user_deleted', "That user account has been deleted.  Please contact your system administrator to have your account re-activated."
      redirect_to login_url
      return
    end
    
    # Call for some cleanups that should be run when a user logs in
    @user = @pseudonym.login_assertions_for_user rescue nil
    
    # Boy there's a lot of code ended up in here...
    
    # When a user logs in we get acccess to their email address as well as their
    # handle.  If the email address that the authentication system returns is
    # different than the email address that the SIS returns, we should give the
    # user the option to add the new address to their account
    if @pseudonym
      begin
        channel = @pseudonym.ldap_channel_to_possibly_merge(params[:pseudonym_session][:password]) rescue nil
        session[:channel_conflict] = channel if channel && @pseudonym.login_path_to_ignore != channel.path
      rescue => e
        ErrorReport.log_exception(:default, e, {
          :message => "LDAP email merge, unexpected error",
        })
      end
    end

    # If the user is registered and logged in, redirect them to their dashboard page
    if @user && @user.registered? && found
      successful_login(@user, @pseudonym)
    # Otherwise re-render the login page to show the error
    else
      respond_to do |format|
        flash[:error] = t 'errors.invalid_credentials', "Incorrect username and/or password"
        @errored = true
        if @user && @user.creation_pending?
          @user.update_attribute(:workflow_state, "pre_registered")
        end
        @pre_registered = @user if @user && !@user.registered?
        @headers = false
        format.html { render :action => "new", :status => :bad_request }
        format.xml  { render :xml => @pseudonym_session.errors.to_xml }
        format.json { render :json => @pseudonym_session.errors.to_json, :status => :bad_request }
      end
    end
  end
  
  def destroy
    # the saml message has to survive a couple redirects and reset_session calls
    message = session[:delegated_message]
    @pseudonym_session.destroy rescue true 

    if @domain_root_account.saml_authentication? and session[:name_id]
      # logout at the saml identity provider
      # once logged out it'll be redirected to here again
      settings = @domain_root_account.account_authorization_config.saml_settings(request.env['canvas.account_domain'])
      request = Onelogin::Saml::LogOutRequest.create(settings, session)
      reset_session
      session[:delegated_message] = message if message
      redirect_to(request)
      return
    elsif @domain_root_account.cas_authentication? and session[:cas_login]
      reset_session
      session[:delegated_message] = message if message
      redirect_to(cas_client.logout_url(login_url))
      return
    else
      reset_session
      flash[:delegated_message] = message if message
    end
    
    flash[:notice] = t 'notices.logged_out', "You are currently logged out"
    flash[:logged_out] = true
    respond_to do |format|
      session[:return_to] = nil
      if @domain_root_account.delegated_authentication?
        format.html { redirect_to login_url(:no_auto=>'true') }
      else
        format.html { redirect_to login_url }
      end
      format.xml { head :ok }
      format.json { render :json => "OK".to_json, :status => :ok }
    end
  end
  
  def clear_file_session
    session['file_access_user_id'] = nil
    session['file_access_expiration'] = nil
    render :text => "ok"
  end
  
  def saml_consume
    if @domain_root_account.saml_authentication? && params[:SAMLResponse]
      settings = @domain_root_account.account_authorization_config.saml_settings(request.env['canvas.account_domain'])
      response = saml_response(params[:SAMLResponse], settings)

      logger.info "Attempting SAML login for #{response.name_id} in account #{@domain_root_account.id}"

      if response.is_valid?
        if response.success_status?
          @pseudonym = nil
          @pseudonym = @domain_root_account.pseudonyms.custom_find_by_unique_id(response.name_id)

          if @pseudonym
            # We have to reset the session again here -- it's possible to do a
            # SAML login without hitting the #new action, depending on the
            # school's setup.
            reset_session_for_login
            #Successful login and we have a user
            @domain_root_account.pseudonym_sessions.create!(@pseudonym, false)
            @user = @pseudonym.login_assertions_for_user rescue nil

            session[:name_id] = response.name_id
            session[:name_qualifier] = response.name_qualifier
            session[:session_index] = response.session_index

            successful_login(@user, @pseudonym)
          else
            logger.warn "Received SAML login request for unknown user: #{response.name_id}"
            # the saml message has to survive a couple redirects
            session[:delegated_message] = t 'errors.no_matching_user', "Canvas doesn't have an account for user: %{user}", :user => response.name_id
            redirect_to :action => :destroy
          end
        elsif response.auth_failure?
          logger.warn "Failed SAML login attempt."
          flash[:delegated_message] = t 'errors.login_error', "There was a problem logging in at %{institution}", :institution => @domain_root_account.display_name
          redirect_to login_url(:no_auto=>'true')
        else
          logger.warn "Unexpected SAML status code - status code: #{response.status_code rescue ""}"
          logger.warn "Status Message: #{response.status_message rescue ""}"
          logger.warn "SAML Response:";i=0;while temp=params[:SAMLResponse][i...i+1500] do logger.warn temp;i+=1500;end
          redirect_to login_url(:no_auto=>'true')
        end
      else
        logger.error "Failed to verify SAML signature."
        logger.warn "SAML Response:";i=0;while temp=params[:SAMLResponse][i...i+1500] do logger.warn temp;i+=1500;end
        @pseudonym_session.destroy rescue true
        reset_session
        flash[:delegated_message] = t 'errors.login_error', "There was a problem logging in at %{institution}", :institution => @domain_root_account.display_name
        redirect_to login_url(:no_auto=>'true')
      end
    elsif !params[:SAMLResponse]
      logger.error "saml_consume request with no SAMLResponse parameter"
      @pseudonym_session.destroy rescue true
      reset_session
      flash[:delegated_message] = t 'errors.login_error', "There was a problem logging in at %{institution}", :institution => @domain_root_account.display_name
      redirect_to login_url(:no_auto=>'true')
    else
      logger.error "Attempted SAML login on non-SAML enabled account."
      @pseudonym_session.destroy rescue true
      reset_session
      flash[:delegated_message] = t 'errors.login_error', "There was a problem logging in at %{institution}", :institution => @domain_root_account.display_name
      redirect_to login_url(:no_auto=>'true')
    end
  end
  
  def saml_logout
    redirect_to :action => :destroy
  end

  def cas_client
    return @cas_client if @cas_client
    config = { :cas_base_url => @domain_root_account.account_authorization_config.auth_base }
    @cas_client = CASClient::Client.new(config)
  end

  def saml_response(raw_response, settings)
    response = Onelogin::Saml::Response.new(raw_response)
    response.settings = settings
    response.logger = logger
    response
  end

  def forbid_on_files_domain
    if HostUrl.is_file_host?(request.host_with_port)
      reset_session
      return redirect_to dashboard_url(:host => HostUrl.default_host)
    end
    true
  end

  def successful_login(user, pseudonym)
    respond_to do |format|
      flash[:notice] = t 'notices.login_success', "Login successful."
      if session[:oauth2]
        # this is where we will verify client authorization and scopes, once implemented
        # .....
        # now generate the temporary code, and respond/redirect
        # (right now we don't support redirect, just oob response using a canvas url)
        code = ActiveSupport::SecureRandom.hex(64)
        code_data = { 'user' => user.id, 'client_id' => session[:oauth2][:client_id] }
        Canvas.redis.setex("oauth2:#{code}", 1.day, code_data.to_json)
        redirect_uri = session[:oauth2][:redirect_uri]
        if redirect_uri == OAUTH2_OOB_URI
          format.html { redirect_to oauth2_auth_url(:code => code) }
        else
          format.html { redirect_to "#{redirect_uri}?code=#{code}" }
        end
      elsif session[:course_uuid] && user && (course = Course.find_by_uuid_and_workflow_state(session[:course_uuid], "created"))
        claim_session_course(course, user)
        format.html { redirect_to(course_url(course, :login_success => '1')) }
      else
        # the URL to redirect back to is stored in the session, so it's
        # assumed that if that URL is found rather than using the default,
        # they must have cookies enabled and we don't need to worry about
        # adding the :login_success param to it.
        format.html { redirect_back_or_default(dashboard_url(:login_success => '1')) }
      end
      format.json { render :json => pseudonym.to_json(:methods => :user_code), :status => :ok }
    end
  end

  OAUTH2_OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'

  def oauth2_auth
    if session[:oauth2] && params[:code]
      # hopefully the user never sees this, since it's an oob response and the
      # browser should be closed automatically. but we'll at least display
      # something basic.
      @pseudonym_session.try(:destroy)
      reset_session
      return render()
    end

    key = DeveloperKey.find_by_id(params[:client_id]) if params[:client_id].present?
    unless key
      return render(:status => 400, :json => { :message => "invalid client_id" })
    end

    redirect_uri = params[:redirect_uri].presence || ""
    unless redirect_uri == OAUTH2_OOB_URI || key.redirect_domain_matches?(redirect_uri)
      return render(:status => 400, :json => { :message => "invalid redirect_uri" })
    end

    session[:oauth2] = { :client_id => key.id, :redirect_uri => redirect_uri }
    # force the user to re-authenticate
    redirect_to login_url(:re_login => true)
  end

  def oauth2_token
    basic_user, basic_pass = ActionController::HttpAuthentication::Basic.user_name_and_password(request) if ActionController::HttpAuthentication::Basic.authorization(request)

    client_id = params[:client_id].presence || basic_user
    key = DeveloperKey.find_by_id(client_id) if client_id.present?
    unless key
      return render(:status => 400, :json => { :message => "invalid client_id" })
    end

    secret = params[:client_secret].presence || basic_pass
    unless secret == key.api_key
      return render(:status => 400, :json => { :message => "invalid client_secret" })
    end

    code = params[:code]
    code_data = JSON.parse(Canvas.redis.get("oauth2:#{code}").presence || "{}")
    unless code_data.present? && code_data['client_id'] == key.id
      return render(:status => 400, :json => { :message => "invalid code" })
    end

    user = User.find(code_data['user'])
    token = AccessToken.create!(:user => user, :developer_key => key)
    render :json => {
      'access_token' => token.token,
      'user' => user.as_json(:only => [:id, :name], :include_root => false),
    }
  end
end
