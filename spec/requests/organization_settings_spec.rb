require "rails_helper"

RSpec.describe "OrganizationSettings" do
  let(:user) { create(:user, :org_admin) }
  let(:organization) { user.organizations.first }

  describe "GET /:slug/settings" do
    context "when signed in as org admin" do
      before { sign_in user }

      it "renders the settings page" do
        get "/#{organization.slug}/settings"
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Organization details")
      end

      context "when org_readme is enabled" do
        before do
          FeatureFlag.add(:org_readme)
          FeatureFlag.enable(:org_readme, FeatureFlag::Actor[organization])
        end

        it "renders the organization pages section link and list block" do
          get "/#{organization.slug}/settings"
          expect(response.body).to include("section-pages-list")
          expect(response.body).to include("No custom pages created yet.")
        end

        it "renders the list of pages if pages exist" do
          create(:page, organization: organization, title: "Our Custom Page Title", slug: "#{organization.slug}/readme", template: "full_within_layout")
          get "/#{organization.slug}/settings"
          expect(response.body).to include("Our Custom Page Title")
          expect(response.body).to include("Showcase")
        end
      end

      it "shows the remove cover image control when a cover image exists" do
        FeatureFlag.add(:org_readme)
        FeatureFlag.enable(:org_readme, FeatureFlag::Actor[organization])
        organization.update!(cover_image: fixture_file_upload("800x600.png", "image/png"))

        get "/#{organization.slug}/settings"

        expect(response.body).to include("organization_remove_cover_image")
      end
    end

    context "when signed in as non-admin member" do
      let(:member) { create(:user) }

      before do
        create(:organization_membership, organization: organization, user: member, type_of_user: "member")
        sign_in member
      end

      it "denies access" do
        expect do
          get "/#{organization.slug}/settings"
        end.to raise_error(Pundit::NotAuthorizedError)
      end
    end

    context "when not signed in" do
      it "redirects to sign in" do
        get "/#{organization.slug}/settings"
        expect(response).to have_http_status(:redirect)
      end
    end
  end

  describe "GET /:slug/settings admin removal permission" do
    let(:checkbox) { 'name="allow_removal"' }
    let(:member) { create(:user) }

    before { create(:organization_membership, user: member, organization: organization, type_of_user: "member") }

    it "shows the checkbox to the admin at the top of a promotion chain" do
      sign_in user

      get "/#{organization.slug}/settings"

      expect(response.body).to include(checkbox)
      expect(response.body).to include("Allow this admin to remove me and other protected admins above me?")
    end

    it "shows the checkbox to an admin who was given the permission" do
      promoted = create(:user)
      create(:organization_membership, user: promoted, organization: organization, type_of_user: "member")
      membership = OrganizationMembership.find_by(user: promoted, organization: organization)
      membership.promote_to_admin!(promoter: OrganizationMembership.find_by(user: user, organization: organization),
                                   allow_removal: true)
      sign_in promoted

      get "/#{organization.slug}/settings"

      expect(response.body).to include(checkbox)
    end

    it "does not show the checkbox to an admin who was not given the permission" do
      promoted = create(:user)
      create(:organization_membership, user: promoted, organization: organization, type_of_user: "member")
      membership = OrganizationMembership.find_by(user: promoted, organization: organization)
      membership.promote_to_admin!(promoter: OrganizationMembership.find_by(user: user, organization: organization),
                                   allow_removal: false)
      sign_in promoted

      get "/#{organization.slug}/settings"

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(checkbox)
    end

    it "marks admins above you as protected and hides the revoke button for them" do
      promoted = create(:user)
      create(:organization_membership, user: promoted, organization: organization, type_of_user: "member")
      OrganizationMembership.find_by(user: promoted, organization: organization)
        .promote_to_admin!(promoter: OrganizationMembership.find_by(user: user, organization: organization),
                           allow_removal: false)
      sign_in promoted

      get "/#{organization.slug}/settings"

      expect(response.body).to include("Protected")
      expect(response.body).not_to include(%(name="user_id" id="user_id" value="#{user.id}"))
    end
  end

  describe "PATCH /:slug/settings" do
    before { sign_in user }

    context "when org_readme is enabled" do
      before do
        FeatureFlag.add(:org_readme)
        FeatureFlag.enable(:org_readme, FeatureFlag::Actor[organization])
      end

      it "removes an existing cover image" do
        organization.update!(cover_image: fixture_file_upload("800x600.png", "image/png"))

        patch "/#{organization.slug}/settings", params: {
          organization: { remove_cover_image: "1" }
        }

        expect(organization.reload.cover_image).to be_blank
      end
    end

    context "when org_readme is disabled" do
      before do
        FeatureFlag.add(:org_readme)
        FeatureFlag.disable(:org_readme, FeatureFlag::Actor[organization])
      end

      it "does not remove a cover image" do
        organization.update!(cover_image: fixture_file_upload("800x600.png", "image/png"))

        patch "/#{organization.slug}/settings", params: {
          organization: { remove_cover_image: "1" }
        }

        expect(organization.reload.cover_image).to be_present
      end
    end

    it "updates organization profile fields" do
      patch "/#{organization.slug}/settings", params: {
        organization: { name: "New Org Name" }
      }
      expect(organization.reload.name).to eq("New Org Name")
    end

    context "when non-admin" do
      let(:member) { create(:user) }

      before do
        create(:organization_membership, organization: organization, user: member, type_of_user: "member")
        sign_in member
      end

      it "denies access" do
        expect do
          patch "/#{organization.slug}/settings", params: {
            organization: { name: "Hacked Name" }
          }
        end.to raise_error(Pundit::NotAuthorizedError)
      end
    end
  end

  describe "POST /:slug/settings/verify" do
    before do
      FeatureFlag.add(:org_verification)
      FeatureFlag.enable(:org_verification, FeatureFlag::Actor[organization])
      organization.update!(url: "https://example.com")
      sign_in user
    end

    it "rejects non-http(s) schemes in verification_url" do
      post organization_request_verification_path(organization.slug), params: {
        verification_url: "javascript://example.com/%0aalert(1)"
      }

      expect(organization.reload.verification_url).to be_nil
    end

    it "normalizes a domain-only verification_url to https://" do
      allow(Organizations::VerifyLinkbackWorker).to receive(:perform_async)

      post organization_request_verification_path(organization.slug), params: {
        verification_url: "example.com/about"
      }

      expect(organization.reload.verification_url).to eq("https://example.com/about")
    end
  end
end
