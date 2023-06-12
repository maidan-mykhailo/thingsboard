--
-- Copyright © 2016-2023 The Thingsboard Authors
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

DROP VIEW IF EXISTS device_info_active_attribute_view CASCADE;
CREATE OR REPLACE VIEW device_info_active_attribute_view AS
SELECT d.*
       , c.title as customer_title
       , COALESCE((c.additional_info::json->>'isPublic')::bool, FALSE) as customer_is_public
       , d.type as device_profile_name
       , COALESCE(da.bool_v, FALSE) as active
FROM device d
         LEFT JOIN customer c ON c.id = d.customer_id
         LEFT JOIN attribute_kv da ON da.entity_type = 'DEVICE' AND da.entity_id = d.id AND da.attribute_type = 'SERVER_SCOPE' AND da.attribute_key = 'active';

DROP VIEW IF EXISTS device_info_active_ts_view CASCADE;
CREATE OR REPLACE VIEW device_info_active_ts_view AS
SELECT d.*
       , c.title as customer_title
       , COALESCE((c.additional_info::json->>'isPublic')::bool, FALSE) as customer_is_public
       , d.type as device_profile_name
       , COALESCE(dt.bool_v, FALSE) as active
FROM device d
         LEFT JOIN customer c ON c.id = d.customer_id
         LEFT JOIN ts_kv_latest dt ON dt.entity_id = d.id and dt.key = (select key_id from ts_kv_dictionary where key = 'active');

DROP VIEW IF EXISTS device_info_view CASCADE;
CREATE OR REPLACE VIEW device_info_view AS SELECT * FROM device_info_active_attribute_view;

DROP VIEW IF EXISTS alarm_info CASCADE;
CREATE VIEW alarm_info AS
SELECT a.*,
(CASE WHEN a.acknowledged AND a.cleared THEN 'CLEARED_ACK'
      WHEN NOT a.acknowledged AND a.cleared THEN 'CLEARED_UNACK'
      WHEN a.acknowledged AND NOT a.cleared THEN 'ACTIVE_ACK'
      WHEN NOT a.acknowledged AND NOT a.cleared THEN 'ACTIVE_UNACK' END) as status,
COALESCE(CASE WHEN a.originator_type = 0 THEN (select title from tenant where id = a.originator_id)
              WHEN a.originator_type = 1 THEN (select title from customer where id = a.originator_id)
              WHEN a.originator_type = 2 THEN (select email from tb_user where id = a.originator_id)
              WHEN a.originator_type = 3 THEN (select title from dashboard where id = a.originator_id)
              WHEN a.originator_type = 4 THEN (select name from asset where id = a.originator_id)
              WHEN a.originator_type = 5 THEN (select name from device where id = a.originator_id)
              WHEN a.originator_type = 9 THEN (select name from entity_view where id = a.originator_id)
              WHEN a.originator_type = 13 THEN (select name from device_profile where id = a.originator_id)
              WHEN a.originator_type = 14 THEN (select name from asset_profile where id = a.originator_id)
              WHEN a.originator_type = 18 THEN (select name from edge where id = a.originator_id) END
    , 'Deleted') originator_name,
COALESCE(CASE WHEN a.originator_type = 0 THEN (select title from tenant where id = a.originator_id)
              WHEN a.originator_type = 1 THEN (select COALESCE(NULLIF(title, ''), email) from customer where id = a.originator_id)
              WHEN a.originator_type = 2 THEN (select email from tb_user where id = a.originator_id)
              WHEN a.originator_type = 3 THEN (select title from dashboard where id = a.originator_id)
              WHEN a.originator_type = 4 THEN (select COALESCE(NULLIF(label, ''), name) from asset where id = a.originator_id)
              WHEN a.originator_type = 5 THEN (select COALESCE(NULLIF(label, ''), name) from device where id = a.originator_id)
              WHEN a.originator_type = 9 THEN (select name from entity_view where id = a.originator_id)
              WHEN a.originator_type = 13 THEN (select name from device_profile where id = a.originator_id)
              WHEN a.originator_type = 14 THEN (select name from asset_profile where id = a.originator_id)
              WHEN a.originator_type = 18 THEN (select COALESCE(NULLIF(label, ''), name) from edge where id = a.originator_id) END
    , 'Deleted') as originator_label,
u.first_name as assignee_first_name, u.last_name as assignee_last_name, u.email as assignee_email
FROM alarm a
LEFT JOIN tb_user u ON u.id = a.assignee_id;

CREATE OR REPLACE FUNCTION create_or_update_active_alarm(
                                        t_id uuid, c_id uuid, a_id uuid, a_created_ts bigint,
                                        a_o_id uuid, a_o_type integer, a_type varchar,
                                        a_severity varchar, a_start_ts bigint, a_end_ts bigint,
                                        a_details varchar,
                                        a_propagate boolean, a_propagate_to_owner boolean,
                                        a_propagate_to_tenant boolean, a_propagation_types varchar,
                                        a_creation_enabled boolean)
    RETURNS varchar
    LANGUAGE plpgsql
AS
$$
DECLARE
    null_id constant uuid = '13814000-1dd2-11b2-8080-808080808080'::uuid;
    existing  alarm;
    result    alarm_info;
    row_count integer;
BEGIN
    SELECT * INTO existing FROM alarm a WHERE a.originator_id = a_o_id AND a.type = a_type AND a.cleared = false ORDER BY a.start_ts DESC FOR UPDATE;
    IF existing.id IS NULL THEN
        IF a_creation_enabled = FALSE THEN
            RETURN json_build_object('success', false)::text;
        END IF;
        IF c_id = null_id THEN
            c_id = NULL;
        end if;
        INSERT INTO alarm
            (tenant_id, customer_id, id, created_time,
             originator_id, originator_type, type,
             severity, start_ts, end_ts,
             additional_info,
             propagate, propagate_to_owner, propagate_to_tenant, propagate_relation_types,
             acknowledged, ack_ts,
             cleared, clear_ts,
             assignee_id, assign_ts)
             VALUES
            (t_id, c_id, a_id, a_created_ts,
             a_o_id, a_o_type, a_type,
             a_severity, a_start_ts, a_end_ts,
             a_details,
             a_propagate, a_propagate_to_owner, a_propagate_to_tenant, a_propagation_types,
             false, 0, false, 0, NULL, 0);
        SELECT * INTO result FROM alarm_info a WHERE a.id = a_id AND a.tenant_id = t_id;
        RETURN json_build_object('success', true, 'created', true, 'modified', true, 'alarm', row_to_json(result))::text;
    ELSE
        UPDATE alarm a
        SET severity                 = a_severity,
            start_ts                 = a_start_ts,
            end_ts                   = a_end_ts,
            additional_info          = a_details,
            propagate                = a_propagate,
            propagate_to_owner       = a_propagate_to_owner,
            propagate_to_tenant      = a_propagate_to_tenant,
            propagate_relation_types = a_propagation_types
        WHERE a.id = existing.id
          AND a.tenant_id = t_id
          AND (severity != a_severity OR start_ts != a_start_ts OR end_ts != a_end_ts OR additional_info != a_details
            OR propagate != a_propagate OR propagate_to_owner != a_propagate_to_owner OR
               propagate_to_tenant != a_propagate_to_tenant OR propagate_relation_types != a_propagation_types);
        GET DIAGNOSTICS row_count = ROW_COUNT;
        SELECT * INTO result FROM alarm_info a WHERE a.id = existing.id AND a.tenant_id = t_id;
        IF row_count > 0 THEN
            RETURN json_build_object('success', true, 'modified', true, 'alarm', row_to_json(result), 'old', row_to_json(existing))::text;
        ELSE
            RETURN json_build_object('success', true, 'modified', false, 'alarm', row_to_json(result))::text;
        END IF;
    END IF;
END
$$;

DROP FUNCTION IF EXISTS update_alarm;
CREATE OR REPLACE FUNCTION update_alarm(t_id uuid, a_id uuid, a_severity varchar, a_start_ts bigint, a_end_ts bigint,
                                        a_details varchar,
                                        a_propagate boolean, a_propagate_to_owner boolean,
                                        a_propagate_to_tenant boolean, a_propagation_types varchar)
    RETURNS varchar
    LANGUAGE plpgsql
AS
$$
DECLARE
    existing  alarm;
    result    alarm_info;
    row_count integer;
BEGIN
    SELECT * INTO existing FROM alarm a WHERE a.id = a_id AND a.tenant_id = t_id FOR UPDATE;
    IF existing IS NULL THEN
        RETURN json_build_object('success', false)::text;
    END IF;
    UPDATE alarm a
    SET severity                 = a_severity,
        start_ts                 = a_start_ts,
        end_ts                   = a_end_ts,
        additional_info          = a_details,
        propagate                = a_propagate,
        propagate_to_owner       = a_propagate_to_owner,
        propagate_to_tenant      = a_propagate_to_tenant,
        propagate_relation_types = a_propagation_types
    WHERE a.id = a_id
      AND a.tenant_id = t_id
      AND (severity != a_severity OR start_ts != a_start_ts OR end_ts != a_end_ts OR additional_info != a_details
        OR propagate != a_propagate OR propagate_to_owner != a_propagate_to_owner OR
           propagate_to_tenant != a_propagate_to_tenant OR propagate_relation_types != a_propagation_types);
    GET DIAGNOSTICS row_count = ROW_COUNT;
    SELECT * INTO result FROM alarm_info a WHERE a.id = a_id AND a.tenant_id = t_id;
    IF row_count > 0 THEN
        RETURN json_build_object('success', true, 'modified', row_count > 0, 'alarm', row_to_json(result), 'old', row_to_json(existing))::text;
    ELSE
        RETURN json_build_object('success', true, 'modified', row_count > 0, 'alarm', row_to_json(result))::text;
    END IF;
END
$$;

DROP FUNCTION IF EXISTS acknowledge_alarm;
CREATE OR REPLACE FUNCTION acknowledge_alarm(t_id uuid, a_id uuid, a_ts bigint)
    RETURNS varchar
    LANGUAGE plpgsql
AS
$$
DECLARE
    existing alarm;
    result   alarm_info;
    modified boolean = FALSE;
BEGIN
    SELECT * INTO existing FROM alarm a WHERE a.id = a_id AND a.tenant_id = t_id FOR UPDATE;
    IF existing IS NULL THEN
        RETURN json_build_object('success', false)::text;
    END IF;

    IF NOT (existing.acknowledged) THEN
        modified = TRUE;
        UPDATE alarm a SET acknowledged = true, ack_ts = a_ts WHERE a.id = a_id AND a.tenant_id = t_id;
    END IF;
    SELECT * INTO result FROM alarm_info a WHERE a.id = a_id AND a.tenant_id = t_id;
    RETURN json_build_object('success', true, 'modified', modified, 'alarm', row_to_json(result), 'old', row_to_json(existing))::text;
END
$$;

DROP FUNCTION IF EXISTS clear_alarm;
CREATE OR REPLACE FUNCTION clear_alarm(t_id uuid, a_id uuid, a_ts bigint, a_details varchar)
    RETURNS varchar
    LANGUAGE plpgsql
AS
$$
DECLARE
    existing alarm;
    result   alarm_info;
    cleared boolean = FALSE;
BEGIN
    SELECT * INTO existing FROM alarm a WHERE a.id = a_id AND a.tenant_id = t_id FOR UPDATE;
    IF existing IS NULL THEN
        RETURN json_build_object('success', false)::text;
    END IF;
    IF NOT(existing.cleared) THEN
        cleared = TRUE;
        IF a_details IS NULL THEN
            UPDATE alarm a SET cleared = true, clear_ts = a_ts WHERE a.id = a_id AND a.tenant_id = t_id;
        ELSE
            UPDATE alarm a SET cleared = true, clear_ts = a_ts, additional_info = a_details WHERE a.id = a_id AND a.tenant_id = t_id;
        END IF;
    END IF;
    SELECT * INTO result FROM alarm_info a WHERE a.id = a_id AND a.tenant_id = t_id;
    RETURN json_build_object('success', true, 'cleared', cleared, 'alarm', row_to_json(result))::text;
END
$$;

DROP FUNCTION IF EXISTS assign_alarm;
CREATE OR REPLACE FUNCTION assign_alarm(t_id uuid, a_id uuid, u_id uuid, a_ts bigint)
    RETURNS varchar
    LANGUAGE plpgsql
AS
$$
DECLARE
    existing alarm;
    result   alarm_info;
    modified boolean = FALSE;
BEGIN
    SELECT * INTO existing FROM alarm a WHERE a.id = a_id AND a.tenant_id = t_id FOR UPDATE;
    IF existing IS NULL THEN
        RETURN json_build_object('success', false)::text;
    END IF;
    IF existing.assignee_id IS NULL OR existing.assignee_id != u_id THEN
        modified = TRUE;
        UPDATE alarm a SET assignee_id = u_id, assign_ts = a_ts WHERE a.id = a_id AND a.tenant_id = t_id;
    END IF;
    SELECT * INTO result FROM alarm_info a WHERE a.id = a_id AND a.tenant_id = t_id;
    RETURN json_build_object('success', true, 'modified', modified, 'alarm', row_to_json(result))::text;
END
$$;

DROP FUNCTION IF EXISTS unassign_alarm;
CREATE OR REPLACE FUNCTION unassign_alarm(t_id uuid, a_id uuid, a_ts bigint)
    RETURNS varchar
    LANGUAGE plpgsql
AS
$$
DECLARE
    existing alarm;
    result   alarm_info;
    modified boolean = FALSE;
BEGIN
    SELECT * INTO existing FROM alarm a WHERE a.id = a_id AND a.tenant_id = t_id FOR UPDATE;
    IF existing IS NULL THEN
        RETURN json_build_object('success', false)::text;
    END IF;
    IF existing.assignee_id IS NOT NULL THEN
        modified = TRUE;
        UPDATE alarm a SET assignee_id = NULL, assign_ts = a_ts WHERE a.id = a_id AND a.tenant_id = t_id;
    END IF;
    SELECT * INTO result FROM alarm_info a WHERE a.id = a_id AND a.tenant_id = t_id;
    RETURN json_build_object('success', true, 'modified', modified, 'alarm', row_to_json(result))::text;
END
$$;
