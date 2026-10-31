require "rails_helper"

RSpec.describe "Organization admin removal permission inheritance" do
  let(:organization) { create(:organization) }
  let(:creator) { create(:user) }

  before { create(:organization_membership, user: creator, organization: organization, type_of_user: "admin") }

  def membership_of(user)
    OrganizationMembership.find_by(user_id: user.id, organization_id: organization.id)
  end

  def new_member
    create(:user).tap do |user|
      create(:organization_membership, user: user, organization: organization, type_of_user: "member")
    end
  end

  # Promotes `user` (a new member by default) to admin on behalf of `promoter`, the way the form does.
  def promote(user, by:, allow_removal: nil)
    sign_in by
    params = { user_id: user.id, organization_id: organization.id }
    params[:allow_removal] = allow_removal unless allow_removal.nil?
    post "/users/add_org_admin", params: params
    membership_of(user)
  end

  def demote(user, by:)
    sign_in by
    post "/users/remove_org_admin", params: { user_id: user.id, organization_id: organization.id }
  end

  def remove_from_org(user, by:)
    sign_in by
    post "/users/remove_from_org", params: { user_id: user.id, organization_id: organization.id }
  end

  # Builds creator -> admins[0] -> admins[1] -> ..., where `allowances` says for each promotion
  # whether the box was ticked.
  def build_chain(allowances)
    promoter = creator
    allowances.map do |allow|
      promoted = promote(new_member, by: promoter, allow_removal: allow ? "1" : "0")
      user = promoted.user
      promoter = user
      user
    end
  end

  describe "promoting an admin" do
    it "records the promotion chain and the permission when the box is ticked" do
      admin = new_member
      membership = promote(admin, by: creator, allow_removal: "1")

      expect(membership).to be_admin
      expect(membership.promotion_chain).to eq([creator.id])
      expect(membership.removable_admin_ids).to eq([creator.id])
    end

    it "keeps the promoter protected when the box is not ticked" do
      membership = promote(new_member, by: creator, allow_removal: "0")

      expect(membership).to be_admin
      expect(membership.promotion_chain).to eq([creator.id])
      expect(membership.removable_admin_ids).to be_empty
    end

    it "keeps the promoter protected when the parameter is missing, as for requests from older forms" do
      expect(promote(new_member, by: creator).removable_admin_ids).to be_empty
    end

    it "treats anything but the checkbox value as unticked" do
      %w[0 nope false].each do |value|
        expect(promote(new_member, by: creator, allow_removal: value).removable_admin_ids).to be_empty
      end
    end

    it "does not let an admin without the permission grant it, even with a hand-crafted request" do
      b = build_chain([false]).first
      c = promote(new_member, by: b, allow_removal: "1")

      expect(c).to be_admin
      expect(c.promotion_chain).to eq([b.id, creator.id])
      expect(c.removable_admin_ids).to be_empty
    end

    it "passes the permission on through every promotion that ticks the box" do
      b, c, d = build_chain([true, true, true])

      expect(membership_of(b).removable_admin_ids).to eq([creator.id])
      expect(membership_of(c).removable_admin_ids).to eq([b.id, creator.id])
      expect(membership_of(d).removable_admin_ids).to eq([c.id, b.id, creator.id])
      expect(membership_of(d).promotion_chain).to eq([c.id, b.id, creator.id])
    end

    it "stops passing the permission on after an unticked promotion" do
      _b, c, d, e = build_chain([true, true, false, true])

      expect(membership_of(c).removable_admin_ids).not_to be_empty
      expect(membership_of(d).removable_admin_ids).to be_empty
      expect(membership_of(e).removable_admin_ids).to be_empty
    end

    it "does not rewrite the chain of someone who is already an admin" do
      b = build_chain([true]).first
      before_promotion = membership_of(creator).attributes.slice("promotion_chain", "removable_admin_ids")

      promote(creator, by: b, allow_removal: "1")

      expect(membership_of(creator).attributes.slice("promotion_chain", "removable_admin_ids"))
        .to eq(before_promotion)
    end

    it "does not let a member promote anyone" do
      member = new_member
      sign_in member

      expect do
        post "/users/add_org_admin", params: { user_id: new_member.id, organization_id: organization.id,
                                               allow_removal: "1" }
      end.to raise_error Pundit::NotAuthorizedError
    end
  end

  describe "removing an admin who is above you" do
    it "is allowed when the promoter allowed it" do
      b = build_chain([true]).first

      demote(creator, by: b)

      expect(membership_of(creator)).not_to be_admin
    end

    it "can take them out of the organization after demoting them" do
      b = build_chain([true]).first

      demote(creator, by: b)
      remove_from_org(creator, by: b)

      expect(membership_of(creator)).to be_nil
    end

    it "is refused when the promoter did not allow it" do
      b = build_chain([false]).first

      expect { demote(creator, by: b) }.to raise_error Pundit::NotAuthorizedError
      expect(membership_of(creator)).to be_admin
    end

    it "is refused for taking a protected admin out of the organization" do
      b = build_chain([false]).first

      expect { remove_from_org(creator, by: b) }.to raise_error Pundit::NotAuthorizedError
      expect(membership_of(creator)).to be_present
    end
  end

  describe "across several promotions" do
    it "lets the last admin remove everyone above when every promotion allowed it" do
      b, c, d, e = build_chain([true, true, true, true])

      [d, c, b, creator].each do |above|
        demote(above, by: e)
        expect(membership_of(above)).not_to be_admin
      end
    end

    it "lets each admin remove only as far up as the permission was passed on" do
      b, c, d, e = build_chain([true, true, false, false])

      # C was given the permission over B and the creator, D and E were not.
      demote(b, by: c)
      expect(membership_of(b)).not_to be_admin
      expect { demote(creator, by: d) }.to raise_error Pundit::NotAuthorizedError
      expect { demote(c, by: d) }.to raise_error Pundit::NotAuthorizedError
      expect { demote(d, by: e) }.to raise_error Pundit::NotAuthorizedError
      expect { demote(creator, by: e) }.to raise_error Pundit::NotAuthorizedError
    end

    it "lets an admin remove the admins below them whatever those admins were allowed" do
      b, c = build_chain([false, false])

      demote(c, by: b)
      expect(membership_of(c)).not_to be_admin

      demote(b, by: creator)
      expect(membership_of(b)).not_to be_admin
    end
  end

  describe "independent promotion chains" do
    it "does not protect admins from admins promoted by someone else" do
      b = promote(new_member, by: creator, allow_removal: "0").user
      x = promote(new_member, by: creator, allow_removal: "0").user

      demote(x, by: b)
      expect(membership_of(x)).not_to be_admin

      promote(x, by: creator, allow_removal: "0")
      demote(b, by: x)
      expect(membership_of(b)).not_to be_admin
      expect(membership_of(creator)).to be_admin
    end

    it "does not protect admins who were added without a promotion chain" do
      legacy = create(:user)
      create(:organization_membership, user: legacy, organization: organization, type_of_user: "admin")

      demote(creator, by: legacy)

      expect(membership_of(creator)).not_to be_admin
    end
  end

  describe "changes in the chain" do
    it "keeps an admin protected after an admin above them in the chain is removed" do
      b, c = build_chain([false, false])
      sibling = promote(new_member, by: creator, allow_removal: "0").user

      remove_from_org(b, by: sibling)
      expect(membership_of(b)).to be_nil

      expect { demote(creator, by: c) }.to raise_error Pundit::NotAuthorizedError
      expect(membership_of(creator)).to be_admin
    end

    it "starts a fresh chain when someone is demoted and promoted again" do
      b = build_chain([true]).first
      demote(b, by: creator)
      expect(membership_of(b).promotion_chain).to be_empty

      promote(b, by: creator, allow_removal: "0")

      expect(membership_of(b).promotion_chain).to eq([creator.id])
      expect(membership_of(b).removable_admin_ids).to be_empty
    end

    it "does not let the permission loop back when admins re-promote each other" do
      b = build_chain([true]).first
      demote(creator, by: b)

      promote(creator, by: b, allow_removal: "1")

      expect(membership_of(creator).promotion_chain).to eq([b.id])
      expect(membership_of(creator).removable_admin_ids).to eq([b.id])
    end
  end

  describe "existing behavior" do
    it "still lets an admin leave the organization" do
      b = build_chain([false]).first
      sign_in b

      post "/users/leave_org/#{organization.id}"

      expect(membership_of(b)).to be_nil
    end

    it "still lets an admin remove ordinary members and pending invitations" do
      member = new_member
      pending_user = create(:user)
      create(:organization_membership, user: pending_user, organization: organization, type_of_user: "pending")
      b = build_chain([false]).first

      remove_from_org(member, by: b)
      remove_from_org(pending_user, by: b)

      expect(membership_of(member)).to be_nil
      expect(membership_of(pending_user)).to be_nil
    end
  end
end
