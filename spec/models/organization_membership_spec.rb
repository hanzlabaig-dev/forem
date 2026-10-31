require "rails_helper"

RSpec.describe OrganizationMembership do
  describe "validations" do
    subject { build(:organization_membership) }

    let(:organization) { create(:organization) }

    it { is_expected.to validate_presence_of(:type_of_user) }
    it { is_expected.to validate_uniqueness_of(:user_id).scoped_to(:organization_id) }
    it { is_expected.to validate_inclusion_of(:type_of_user).in_array(OrganizationMembership::USER_TYPES) }
  end

  describe "admin promotion chain" do
    let(:organization) { create(:organization) }
    let(:creator) { create(:user) }
    let(:creator_membership) do
      create(:organization_membership, user: creator, organization: organization, type_of_user: "admin")
    end

    def member_membership
      create(:organization_membership, user: create(:user), organization: organization, type_of_user: "member")
    end

    describe "#can_remove?" do
      it "lets an admin without a chain remove anyone" do
        expect(creator_membership.can_remove?(create(:user).id)).to be(true)
      end

      it "lets an admin remove themselves" do
        membership = member_membership.tap do |m|
          m.promote_to_admin!(promoter: creator_membership, allow_removal: false)
        end

        expect(membership.can_remove?(membership.user_id)).to be(true)
      end

      it "protects the admins above an admin unless they allowed removal" do
        membership = member_membership.tap do |m|
          m.promote_to_admin!(promoter: creator_membership, allow_removal: false)
        end

        expect(membership.can_remove?(creator.id)).to be(false)
        expect(membership.can_remove?(create(:user).id)).to be(true)
      end

      it "lets an admin remove the admins above them who allowed it" do
        membership = member_membership.tap do |m|
          m.promote_to_admin!(promoter: creator_membership, allow_removal: true)
        end

        expect(membership.can_remove?(creator.id)).to be(true)
      end
    end

    describe "#can_grant_removal_permission?" do
      it "is true for the admin at the top of a chain" do
        expect(creator_membership.can_grant_removal_permission?).to be(true)
      end

      it "is true for an admin who was given the permission and false for one who was not" do
        allowed = member_membership.tap { |m| m.promote_to_admin!(promoter: creator_membership, allow_removal: true) }
        refused = member_membership.tap { |m| m.promote_to_admin!(promoter: creator_membership, allow_removal: false) }

        expect(allowed.can_grant_removal_permission?).to be(true)
        expect(refused.can_grant_removal_permission?).to be(false)
      end

      it "is false for members" do
        expect(member_membership.can_grant_removal_permission?).to be(false)
      end
    end

    describe "#promote_to_admin!" do
      it "ignores allow_removal when the promoter does not hold the permission" do
        refused = member_membership.tap { |m| m.promote_to_admin!(promoter: creator_membership, allow_removal: false) }
        promoted = member_membership

        promoted.promote_to_admin!(promoter: refused, allow_removal: true)

        expect(promoted.removable_admin_ids).to be_empty
        expect(promoted.promotion_chain).to eq([refused.user_id, creator.id])
      end

      it "never lists the promoted admin in their own chain" do
        creator_membership
        promoted = member_membership
        promoted.promote_to_admin!(promoter: creator_membership, allow_removal: true)
        creator_membership.update!(type_of_user: "member")

        creator_membership.promote_to_admin!(promoter: promoted, allow_removal: true)

        expect(creator_membership.promotion_chain).to eq([promoted.user_id])
        expect(creator_membership.removable_admin_ids).to eq([promoted.user_id])
      end
    end

    it "clears the chain when an admin stops being an admin" do
      membership = member_membership.tap { |m| m.promote_to_admin!(promoter: creator_membership, allow_removal: true) }

      membership.update!(type_of_user: "member")

      expect(membership.reload.promotion_chain).to be_empty
      expect(membership.removable_admin_ids).to be_empty
    end

    it "does not allow removable admins that are not in the chain" do
      membership = build(:organization_membership, type_of_user: "admin", promotion_chain: [1],
                                                   removable_admin_ids: [1, 2])

      expect(membership).not_to be_valid
      expect(membership.errors[:removable_admin_ids]).to be_present
    end
  end

  describe "scopes" do
    let(:organization) { create(:organization) }
    let(:user1) { create(:user) }
    let(:user2) { create(:user) }
    let(:user3) { create(:user) }

    before do
      create(:organization_membership, organization: organization, user: user1, type_of_user: "admin")
      create(:organization_membership, organization: organization, user: user2, type_of_user: "member")
      create(:organization_membership, organization: organization, user: user3, type_of_user: "pending")
    end

    describe ".pending" do
      it "returns only pending memberships" do
        expect(organization.organization_memberships.pending.count).to eq(1)
        expect(organization.organization_memberships.pending.first.user).to eq(user3)
      end
    end

    describe ".active" do
      it "returns only non-pending memberships" do
        expect(organization.organization_memberships.active.count).to eq(2)
        expect(organization.organization_memberships.active.pluck(:user_id)).to contain_exactly(user1.id, user2.id)
      end
    end
  end

  describe "#pending?" do
    it "returns true for pending memberships" do
      membership = create(:organization_membership, type_of_user: "pending")
      expect(membership.pending?).to be true
    end

    it "returns false for non-pending memberships" do
      membership = create(:organization_membership, type_of_user: "member")
      expect(membership.pending?).to be false
    end
  end

  describe "#confirm!" do
    let(:membership) { create(:organization_membership, type_of_user: "pending") }

    it "changes type_of_user from pending to member" do
      expect(membership.type_of_user).to eq("pending")
      membership.confirm!
      expect(membership.reload.type_of_user).to eq("member")
    end

    it "updates the membership" do
      expect { membership.confirm! }.to change { membership.reload.type_of_user }.from("pending").to("member")
    end

    it "touches the user's organization_info_updated_at so profile caches refresh" do
      membership.user.update_column(:organization_info_updated_at, 1.day.ago)
      previous_timestamp = membership.user.reload.organization_info_updated_at
      membership.confirm!
      expect(membership.user.reload.organization_info_updated_at).to be > previous_timestamp
    end
  end

  describe "invitation_token generation" do
    it "generates an invitation token for pending memberships" do
      membership = build(:organization_membership, type_of_user: "pending", invitation_token: nil)
      membership.save!
      expect(membership.invitation_token).to be_present
    end

    it "does not generate an invitation token for non-pending memberships" do
      membership = build(:organization_membership, type_of_user: "member", invitation_token: nil)
      membership.save!
      expect(membership.invitation_token).to be_nil
    end

    it "preserves existing invitation token if present" do
      existing_token = "existing-token-123"
      membership = build(:organization_membership, type_of_user: "pending", invitation_token: existing_token)
      membership.save!
      expect(membership.invitation_token).to eq(existing_token)
    end
  end

  describe "recompiling organization pages" do
    let(:organization) { create(:organization) }
    let(:user) { create(:user) }

    before do
      allow(Organizations::RecompilePagesWorker).to receive(:perform_async)
      allow(FeatureFlag).to receive(:enabled?).and_call_original
      allow(FeatureFlag).to receive(:enabled?).with(:org_readme, anything).and_return(true)
    end

    it "enqueues recompilation on create" do
      create(:organization_membership, organization: organization, user: user)
      expect(Organizations::RecompilePagesWorker).to have_received(:perform_async).with(organization.id)
    end

    it "enqueues recompilation on update" do
      membership = create(:organization_membership, organization: organization, user: user, type_of_user: "pending")
      membership.update!(type_of_user: "member")
      expect(Organizations::RecompilePagesWorker).to have_received(:perform_async).with(organization.id).twice
    end

    it "enqueues recompilation on destroy" do
      membership = create(:organization_membership, organization: organization, user: user)
      membership.destroy!
      expect(Organizations::RecompilePagesWorker).to have_received(:perform_async).with(organization.id).twice
    end
  end
end
