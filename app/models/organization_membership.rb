#  @note When we destroy the related user, it's using dependent:
#        :delete for the relationship.  That means no before/after
#        destroy callbacks will be called on this object.
class OrganizationMembership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  USER_TYPES = %w[admin member guest pending].freeze

  validates :type_of_user, presence: true
  validates :user_id, uniqueness: { scope: :organization_id }
  validates :type_of_user, inclusion: { in: USER_TYPES }
  validate :removable_admins_are_in_promotion_chain

  before_create :generate_invitation_token, if: -> { type_of_user == "pending" && invitation_token.blank? }
  before_update :clear_promotion_chain, if: -> { will_save_change_to_type_of_user? && type_of_user != "admin" }

  after_create  :update_user_organization_info_updated_at
  after_update  :update_user_organization_info_updated_at, if: :saved_change_to_type_of_user?
  after_destroy :update_user_organization_info_updated_at

  after_commit :bust_cache
  after_commit :recompile_organization_pages

  scope :admin, -> { where(type_of_user: "admin") }
  scope :member, -> { where(type_of_user: %w[admin member]) }
  scope :pending, -> { where(type_of_user: "pending") }
  scope :active, -> { where.not(type_of_user: "pending") }

  def pending?
    type_of_user == "pending"
  end

  def admin?
    type_of_user == "admin"
  end

  # Whether this admin may remove (demote or take out of the organization) the given user.
  #
  # Everyone can be removed except the admins above this one in their promotion chain, unless they
  # allowed this admin to remove them. Admins who aren't in a chain are not protected from anyone.
  #
  # @param target_user_id [Integer]
  def can_remove?(target_user_id)
    return true if target_user_id == user_id

    !promotion_chain.include?(target_user_id) || removable_admin_ids.include?(target_user_id)
  end

  # Whether this admin may let an admin they promote remove them (and pass the permission on): true
  # for the admin at the top of a chain, and for admins who were given the permission themselves.
  def can_grant_removal_permission?
    admin? && (promotion_chain.empty? || can_remove_promoter?)
  end

  def confirm!
    update!(type_of_user: "member")
  end

  # Makes this member an admin and records their promotion chain.
  #
  # The permission to remove the promoter and the admins above them is only given when the promoter
  # holds it themselves, so it can never be handed out by someone who was not given it.
  #
  # @param promoter [OrganizationMembership] the promoting admin's membership in the same organization
  # @param allow_removal [Boolean] whether the new admin may remove the promoter and the protected
  #   admins above them, and pass that permission on
  def promote_to_admin!(promoter:, allow_removal:)
    chain = ([promoter.user_id] + promoter.promotion_chain) - [user_id]
    grant = allow_removal && promoter.can_grant_removal_permission?
    removable = grant ? ([promoter.user_id] + promoter.removable_admin_ids) - [user_id] : []

    update!(type_of_user: "admin", promotion_chain: chain, removable_admin_ids: removable)
  end

  private

  # Someone who stops being an admin leaves the promotion chain, so a later promotion starts afresh.
  def clear_promotion_chain
    self.promotion_chain = []
    self.removable_admin_ids = []
  end

  def can_remove_promoter?
    removable_admin_ids.include?(promotion_chain.first)
  end

  def removable_admins_are_in_promotion_chain
    return if (removable_admin_ids - promotion_chain).empty?

    errors.add(:removable_admin_ids, "must only contain admins from the promotion chain")
  end

  def generate_invitation_token
    self.invitation_token = SecureRandom.urlsafe_base64(32)
  end

  # @note In the case where we delete the user, we don't need to worry
  #       about updating the user.  Hence the the `user has_many
  #       :organization_memberships dependent: :delete_all`
  def update_user_organization_info_updated_at
    user.touch(:organization_info_updated_at)
  end

  def recompile_organization_pages
    return unless FeatureFlag.enabled?(:org_readme, FeatureFlag::Actor[organization_id])

    Organizations::RecompilePagesWorker.perform_async(organization_id)
  end

  def bust_cache
    BustCachePathWorker.perform_async(organization.path.to_s)
    EdgeCache::PurgeByKey.call(organization.path.to_s)
  rescue StandardError => e
    Rails.logger.error("Failed to purge organization cache for #{organization.id}: #{e.class} - #{e.message}")
  end
end
