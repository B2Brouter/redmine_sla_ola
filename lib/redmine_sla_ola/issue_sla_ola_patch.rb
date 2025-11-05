module RedmineSlaOla
  module IssueSlaOlaPatch
    def self.included(base)
      base.class_eval do
        after_commit :set_sla_and_ola_limits
      end
    end

    private

    def set_sla_and_ola_limits
      return true unless project_id.present?
      return true unless self.sla_limit.blank? && self.ola_limit.blank?
      return true unless self.created_on.present?

      product_value = custom_value_for_products
      return true if product_value.blank?

      policy = find_policy_for(project_id, product_value)
      return true unless policy

      base_time = self.created_on || Time.zone.now

      if self.sla_limit.blank? && policy.sla_delay.present?
        self.sla_limit = compute_deadline(
          base_time,
          policy.sla_delay.to_f,
          policy.business_hours_start&.strftime("%H:%M"),
          policy.business_hours_end&.strftime("%H:%M"),
          policy.business_days
        )
      end

      if self.ola_limit.blank? && policy.ola_delay.present?
        self.ola_limit = compute_deadline(
          base_time,
          policy.ola_delay.to_f,
          policy.business_hours_start&.strftime("%H:%M"),
          policy.business_hours_end&.strftime("%H:%M"),
          policy.business_days
        )
      end

      if self.sla_limit || self.ola_limit
        self.update_columns(
          sla_limit: self.sla_limit,
          ola_limit: self.ola_limit,
          updated_on: Time.zone.now
        )
      end

      true
    end

    def custom_value_for_products
      cf = CustomField.find_by(name: 'Products')
      return nil unless cf
      cv = custom_values.detect { |v| v.custom_field_id == cf.id }
      cv&.value.to_s.strip
    end

    def find_policy_for(project_id, product_value)
      LevelAgreementPolicy
        .where(project_id: project_id)
        .where('products LIKE ?', "%- #{product_value}%")
        .first
    end

    def compute_deadline(start_time, hours_to_add, bh_start, bh_end, business_days_str)
      return start_time + hours_to_add.hours if bh_start.blank? || bh_end.blank? || business_days_str.blank?

      bh_start_h, bh_start_m, _ = bh_start.to_s.split(':').map(&:to_i)
      bh_end_h,   bh_end_m,   _ = bh_end.to_s.split(':').map(&:to_i)

      business_days = business_days_str.to_s.downcase.split(/\s*,\s*/).map(&:strip)

      minutes_left = (hours_to_add * 60).ceil
      current = start_time

      while minutes_left > 0
        unless business_days.include?(current.wday.to_s)
          current = next_business_start(current.to_date + 1.day, bh_start_h, bh_start_m, business_days)
          next
        end

        day_start = current.change(hour: bh_start_h, min: bh_start_m, sec: 0)
        day_end   = current.change(hour: bh_end_h,   min: bh_end_m,   sec: 0)

        if current < day_start
          current = day_start
        end

        if current >= day_end
          current = next_business_start(current.to_date + 1.day, bh_start_h, bh_start_m, business_days)
          next
        end

        usable_minutes_today = [(day_end - current) / 60.0, minutes_left].min.ceil
        current += usable_minutes_today.minutes
        minutes_left -= usable_minutes_today

        if minutes_left > 0 && current >= day_end
          current = next_business_start(current.to_date + 1.day, bh_start_h, bh_start_m, business_days)
        end
      end

      current
    end

    def next_business_start(date, h, m, business_days)
      d = date
      until business_days.include?(d.wday.to_s)
        d += 1.day
      end
      Time.zone.local(d.year, d.month, d.day, h, m, 0)
    end
  end
end
