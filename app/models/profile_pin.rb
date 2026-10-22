# @note When we destroy the related article (via pinnable), it's using
#       dependent: :delete for the relationship.  That means no
#       before/after destroy callbacks will be called on this object.
class ProfilePin < ApplicationRecord
  belongs_to :pinnable, polymorphic: true
  belongs_to :profile, polymorphic: true

  validates :profile_type, inclusion: { in: %w[User Organization] }
  validates :pinnable_id, uniqueness: { scope: %i[profile_id profile_type pinnable_type] }
  validates :pinnable_type, inclusion: { in: %w[Article] } # Future could be comments, etc.
  validate :only_five_pins_per_profile, on: :create
  validate :pinnable_belongs_to_profile

  private

  def only_five_pins_per_profile
    errors.add(:base, I18n.t("models.profile_pin.only_five")) if profile.profile_pins.size > 4
  end

  def pinnable_belongs_to_profile
    return unless pinnable && profile

    permitted = if profile.is_a?(User)
                  pinnable.user_id == profile_id
                elsif profile.is_a?(Organization)
                  pinnable.organization_id == profile_id
                else
                  false
                end
    errors.add(:pinnable_id, I18n.t("models.profile_pin.pin_unpermitted")) unless permitted
  end
end
