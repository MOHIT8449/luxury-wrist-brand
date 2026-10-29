-- Admin / Sales Head creates a fully approved PO in one transaction.
-- Salesman submission and existing pending POs are unchanged.
BEGIN;
CREATE OR REPLACE FUNCTION public.lwb_head_create_approved_po(
  p_customer_name text, p_transportation text, p_sales_person text,
  p_order_date timestamptz, p_items jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY INVOKER SET search_path = ''
AS $fn$
DECLARE
  v_user uuid := auth.uid();
  v_order public.orders%ROWTYPE;
  v_item jsonb;
  v_sku public.sku_master%ROWTYPE;
  v_qty numeric; v_rate numeric; v_weight numeric;
  v_pallet integer; v_cpp integer; v_uom text;
  v_lines jsonb := '[]'::jsonb;
  v_seen text[] := ARRAY[]::text[];
  v_total_qty numeric := 0; v_total_amount numeric := 0; v_total_weight numeric := 0;
BEGIN
  -- Check the actual login role, never page access, a supplied salesman name or JWT user metadata.
  IF v_user IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.user_profiles p WHERE p.id=v_user AND p.active=true
      AND lower(btrim(p.role)) IN ('admin','manager')
  ) THEN RAISE EXCEPTION 'Active Admin or Sales Head required' USING ERRCODE='42501'; END IF;
  IF nullif(btrim(p_customer_name),'') IS NULL OR nullif(btrim(p_sales_person),'') IS NULL THEN
    RAISE EXCEPTION 'Party and sales person are required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.lwb_customer_master c
    WHERE upper(btrim(c.customer_name))=upper(btrim(p_customer_name)) AND c.is_active=true) THEN
    RAISE EXCEPTION 'Select an active party from Party Master';
  END IF;
  IF coalesce(btrim(p_transportation),'')<>'' AND p_transportation !~
    '^(SELF PICKUP|DELIVERY|DIRECT VEHICLE)( \| VEHICLE: [A-Z0-9 -]{5,25})?( \| QTY: PALLET)?$' THEN
    RAISE EXCEPTION 'Invalid transportation';
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'SKU items must be a list'; END IF;
  IF jsonb_array_length(p_items) NOT BETWEEN 1 AND 500 THEN RAISE EXCEPTION 'Enter 1 to 500 SKU lines'; END IF;
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items) LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'Invalid SKU line'; END IF;
    SELECT * INTO v_sku FROM public.sku_master s
      WHERE upper(btrim(s.sku_name))=upper(btrim(v_item->>'sku_name')) AND s.is_active=true LIMIT 1;
    IF NOT FOUND THEN RAISE EXCEPTION 'Select an active SKU from SKU Master'; END IF;
    IF upper(btrim(v_sku.sku_name))=ANY(v_seen) THEN RAISE EXCEPTION 'Duplicate SKU line'; END IF;
    v_seen:=array_append(v_seen,upper(btrim(v_sku.sku_name)));
    v_qty:=(v_item->>'ordered_qty')::numeric;
    v_rate:=(v_item->>'rate')::numeric;
    IF v_qty IS NULL OR NOT (v_qty BETWEEN 1 AND 2147483647) OR trunc(v_qty)<>v_qty THEN
      RAISE EXCEPTION 'Enter positive whole-number cases';
    END IF;
    IF v_rate IS NULL OR NOT (v_rate BETWEEN 0 AND 1000000000000) THEN RAISE EXCEPTION 'Invalid rate'; END IF;
    v_weight:=coalesce(v_sku.unit_weight_kg,0);
    IF NOT (v_weight BETWEEN 0 AND 1000000000) THEN RAISE EXCEPTION 'Invalid SKU Master weight'; END IF;
    v_uom:=coalesce(v_item->>'entry_uom','CS');v_pallet:=NULL;v_cpp:=NULL;
    IF v_uom='PALLET' THEN
      IF p_transportation IS NULL OR p_transportation NOT LIKE 'DIRECT VEHICLE%' THEN RAISE EXCEPTION 'Pallet entry requires Direct vehicle'; END IF;
      IF coalesce(v_item->>'ordered_pallet_qty','') !~ '^[1-9][0-9]*$' THEN RAISE EXCEPTION 'Enter whole-number pallets'; END IF;
      v_pallet:=(v_item->>'ordered_pallet_qty')::integer;
      v_cpp:=v_sku.cases_per_pallet;
      IF v_cpp IS NULL OR v_cpp<1 OR v_qty<>v_pallet::numeric*v_cpp
        OR (v_item->>'cases_per_pallet_snapshot')::integer IS DISTINCT FROM v_cpp THEN
        RAISE EXCEPTION 'Cases per pallet changed. Refresh SKU Master and retry';
      END IF;
    ELSIF v_uom<>'CS' THEN RAISE EXCEPTION 'Invalid quantity mode'; END IF;
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
      'sku_name',v_sku.sku_name,'ordered_qty',v_qty,'approved_qty',v_qty,'loaded_qty',0,
      'rate',v_rate,'unit_weight',v_weight,'amount',v_qty*v_rate,'total_weight',v_qty*v_weight,
      'entry_uom',v_uom,'ordered_pallet_qty',v_pallet,'cases_per_pallet_snapshot',v_cpp));
    v_total_qty:=v_total_qty+v_qty;v_total_amount:=v_total_amount+v_qty*v_rate;v_total_weight:=v_total_weight+v_qty*v_weight;
  END LOOP;
  -- Insert as approved so the pending-approval notification trigger does not ask for review.
  -- All SKU inserts and existing party/KYC guards are in this same transaction.
  INSERT INTO public.orders(order_no,order_date,customer_name,transportation,sales_person,status,
    total_qty,total_amount,total_weight,created_by,approved_by,approved_at)
  VALUES(public.lwb_next_order_no(),coalesce(p_order_date,now()),btrim(p_customer_name),nullif(btrim(p_transportation),''),
    btrim(p_sales_person),'approved',v_total_qty,v_total_amount,v_total_weight,v_user,v_user,now()) RETURNING * INTO v_order;
  INSERT INTO public.order_items(order_id,sku_name,ordered_qty,approved_qty,loaded_qty,rate,unit_weight,amount,total_weight,
    entry_uom,ordered_pallet_qty,cases_per_pallet_snapshot)
  SELECT v_order.id,x.sku_name,x.ordered_qty,x.approved_qty,x.loaded_qty,x.rate,x.unit_weight,x.amount,x.total_weight,
    x.entry_uom,x.ordered_pallet_qty,x.cases_per_pallet_snapshot
  FROM jsonb_to_recordset(v_lines) AS x(sku_name text,ordered_qty numeric,approved_qty numeric,loaded_qty numeric,
    rate numeric,unit_weight numeric,amount numeric,total_weight numeric,entry_uom text,ordered_pallet_qty integer,cases_per_pallet_snapshot integer);
  RETURN jsonb_build_object('id',v_order.id,'order_no',v_order.order_no,'status',v_order.status,
    'total_qty',v_total_qty,'total_amount',v_total_amount,'total_weight',v_total_weight);
END;
$fn$;
REVOKE ALL ON FUNCTION public.lwb_head_create_approved_po(text,text,text,timestamptz,jsonb) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.lwb_head_create_approved_po(text,text,text,timestamptz,jsonb) TO authenticated;
COMMENT ON FUNCTION public.lwb_head_create_approved_po(text,text,text,timestamptz,jsonb)
  IS 'Atomic PO creation for active Admin / Sales Head only; creator and approval identity come from auth.uid().';
COMMIT;
