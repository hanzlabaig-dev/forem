class ProfilePinsController < ApplicationController
  before_action :authenticate_user!, only: %i[create update organization_create organization_destroy]
  before_action :set_organization, only: %i[organization_create organization_destroy]
  before_action :authorize_organization_admin!, only: %i[organization_create organization_destroy]

  def create
    @profile_pin = ProfilePin.new
    @profile_pin.profile_id = current_user.id
    @profile_pin.profile_type = "User"
    @profile_pin.pinnable_id = profile_pin_params[:pinnable_id].to_i
    @profile_pin.pinnable_type = "Article"
    if @profile_pin.save
      flash[:success] = I18n.t("views.pins.pinned")
    else
      flash[:error] = I18n.t("views.pins.error")
    end
    redirect_back(fallback_location: "/dashboard")
    bust_user_profile
  end

  def update
    current_user.profile_pins.destroy_by(id: params[:id])
    bust_user_profile
    flash[:success] = I18n.t("views.pins.removed")
    redirect_back(fallback_location: "/dashboard")
  end

  def organization_create
    article = @organization.articles.published.find_by(id: params[:article_id])
    if article.nil?
      flash[:error] = I18n.t("views.pins.organization_article_unavailable")
    else
      profile_pin = @organization.profile_pins.find_or_initialize_by(pinnable: article)
      if profile_pin.persisted? || profile_pin.save
        flash[:success] = I18n.t("views.pins.organization_pinned")
      else
        flash[:error] = I18n.t("views.pins.organization_pin_error")
      end
    end
    bust_organization_profile
    redirect_back(fallback_location: @organization.path)
  end

  def organization_destroy
    @organization.profile_pins.destroy_by(id: params[:id])
    bust_organization_profile
    flash[:success] = I18n.t("views.pins.organization_unpinned")
    redirect_back(fallback_location: @organization.path)
  end

  private

  def set_organization
    @organization = Organization.find_by!(slug: params[:slug])
  end

  def authorize_organization_admin!
    authorize @organization, :update?, policy_class: OrganizationPolicy
  end

  def profile_pin_params
    params.require(:profile_pin).permit(:pinnable_id)
  end

  def bust_user_profile
    cache_bust = EdgeCache::Bust.new
    cache_bust.call(current_user.path)
    cache_bust.call("#{current_user.path}?i=i")
  end

  def bust_organization_profile
    EdgeCache::Bust.new.call(@organization.path)
  end
end
