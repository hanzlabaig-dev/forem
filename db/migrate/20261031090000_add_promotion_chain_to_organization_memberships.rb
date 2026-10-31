class AddPromotionChainToOrganizationMemberships < ActiveRecord::Migration[8.0]
  def change
    # User ids of the admins who promoted this admin, nearest first (promoter, their promoter, ...).
    # Existing admins get an empty chain: they are not protected from anyone, as before.
    add_column :organization_memberships, :promotion_chain, :bigint, array: true, default: [], null: false

    # The subset of the chain this admin is allowed to remove. It is a snapshot taken at promotion
    # time, so the permission survives later changes to the admins above (demotion, removal).
    add_column :organization_memberships, :removable_admin_ids, :bigint, array: true, default: [], null: false
  end
end
