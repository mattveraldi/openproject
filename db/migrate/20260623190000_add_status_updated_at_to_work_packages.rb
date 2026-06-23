# frozen_string_literal: true

#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See COPYRIGHT and LICENSE files for more details.
#++

class AddStatusUpdatedAtToWorkPackages < ActiveRecord::Migration[7.1]
  def up
    add_column :work_packages, :status_updated_at, :datetime, precision: nil

    # Initialize from the most recent journal where the status changed,
    # falling back to updated_at when no such journal exists.
    execute <<~SQL
      UPDATE work_packages wp
      SET status_updated_at = COALESCE(
        (
          SELECT j.updated_on
          FROM journals j
          INNER JOIN work_package_journals wpj ON wpj.journal_id = j.id
          WHERE j.journable_type = 'WorkPackage'
            AND j.journable_id = wp.id
            AND wpj.status_id = wp.status_id
          ORDER BY j.updated_on DESC
          LIMIT 1
        ),
        wp.updated_at
      )
    SQL
  end

  def down
    remove_column :work_packages, :status_updated_at
  end
end
