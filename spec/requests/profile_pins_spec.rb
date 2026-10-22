require "rails_helper"

RSpec.describe "ProfilePins" do
  let(:user) { create(:user) }
  let(:article) { create(:article, user_id: user.id) }
  let(:article2) { create(:article, user_id: user.id) }
  let(:article3) { create(:article, user_id: user.id) }
  let(:article4) { create(:article, user_id: user.id) }
  let(:article5) { create(:article, user_id: user.id) }
  let(:article6) { create(:article, user_id: user.id) }
  let(:article7) { create(:article, user_id: user.id) }

  before { sign_in user }

  describe "POST /profile_pins" do
    it "creates a pin" do
      post "/profile_pins", params: {
        profile_pin: { pinnable_id: article.id }
      }
      expect(ProfilePin.last.pinnable_id).to eq(article.id)
    end

    it "allows only five pins" do
      articles = [article, article2, article3, article4, article5, article6, article7]
      articles.each do |a|
        post "/profile_pins", params: {
          profile_pin: { pinnable_id: a.id }
        }
      end
      expect(user.reload.profile_pins.size).to eq(5)
    end
  end

  describe "organization post pinning" do
    let(:organization) { create(:organization) }
    let(:organization_admin) { create(:user) }
    let(:organization_article) { create(:article, user: organization_admin, organization: organization, published: true) }

    before do
      create(:organization_membership, user: organization_admin, organization: organization, type_of_user: "admin")
      sign_in organization_admin
    end

    it "allows organization admins to pin an article published by their organization" do
      post "/organizations/#{organization.slug}/profile_pins", params: { article_id: organization_article.id }

      expect(response).to have_http_status(:redirect)
      expect(organization.reload.profile_pins.pluck(:pinnable_id)).to include(organization_article.id)
    end

    it "does not allow non-admins to pin organization posts" do
      sign_in create(:user)

      post "/organizations/#{organization.slug}/profile_pins", params: { article_id: organization_article.id }

      expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
      expect(organization.reload.profile_pins).to be_empty
    end

    it "does not allow pinning an article from another organization" do
      other_organization = create(:organization)
      other_article = create(:article, user: organization_admin, organization: other_organization, published: true)

      post "/organizations/#{organization.slug}/profile_pins", params: { article_id: other_article.id }

      expect(organization.reload.profile_pins).to be_empty
    end

    it "allows at most five featured posts per organization" do
      articles = create_list(:article, 6, user: organization_admin, organization: organization, published: true)

      articles.each do |article_record|
        post "/organizations/#{organization.slug}/profile_pins", params: { article_id: article_record.id }
      end

      expect(organization.reload.profile_pins.count).to eq(5)
    end

    it "allows organization admins to unpin a featured post" do
      pin = create(:profile_pin, profile: organization, pinnable: organization_article)

      delete "/organizations/#{organization.slug}/profile_pins/#{pin.id}"

      expect(organization.reload.profile_pins).to be_empty
    end
  end

  describe "PUT /profile_pins/:id" do # delete
    it "adds pin on behalf of current user" do
      profile_pin = create(:profile_pin, pinnable: article, profile: user)
      put "/profile_pins/#{profile_pin.id}"
      expect(ProfilePin.all.size).to eq(0)
    end
  end
end
