import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

// lwb_goods_inward_driver_optional.sql on a stand-in of the live lwb_post_goods_inward
// (its real source is not in the repo): strict driver name / mobile checks + table rules.
const db=new PGlite();
await db.exec(`
CREATE TABLE public.lwb_goods_inward(id bigserial primary key,invoice_no text,
  driver_name text NOT NULL CHECK (char_length(btrim(driver_name)) BETWEEN 1 AND 100),
  driver_mobile text NOT NULL,
  CONSTRAINT gi_mobile_ok CHECK (driver_mobile ~ '^[6-9][0-9]{9}$'));
CREATE FUNCTION public.lwb_post_goods_inward(p_invoice_no text,p_driver_name text,p_driver_mobile text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_name text := btrim(coalesce(p_driver_name,'')); v_mob text := regexp_replace(coalesce(p_driver_mobile,''),'\\D','','g'); v_id bigint;
BEGIN
  IF p_invoice_no IS NULL THEN RAISE EXCEPTION 'Enter Invoice No.'; END IF;
  IF char_length(v_name) NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'Enter Driver Name (1 to 100 characters)'; END IF;
  IF true THEN IF v_mob !~ '^[6-9][0-9]{9}$' THEN RAISE EXCEPTION 'Enter valid Driver Mobile (10 digits)'; END IF; END IF;
  INSERT INTO public.lwb_goods_inward(invoice_no,driver_name,driver_mobile) VALUES (p_invoice_no,nullif(v_name,''),nullif(v_mob,'')) RETURNING id INTO v_id;
  RETURN v_id;
END $$;
`);
const sql=await readFile(new URL('../../lwb_goods_inward_driver_optional.sql',import.meta.url),'utf8');
await db.exec(sql);
await db.exec(sql); // safe to run again
const post=(inv,n,m)=>db.query('select public.lwb_post_goods_inward($1,$2,$3) id',[inv,n,m]);

test('blank driver name and mobile save',async()=>{
  assert.ok((await post('A1','','')).rows[0].id);
  assert.ok((await post('A2',null,null)).rows[0].id);
});
test('typed values still checked',async()=>{
  assert.ok((await post('B1','Ramesh','9876543210')).rows[0].id);
  await assert.rejects(post('B2','x'.repeat(101),''),/Driver Name/);
  await assert.rejects(post('B3','Ramesh','12345'),/Driver Mobile/);
  await assert.rejects(post(null,'',''),/Invoice/);
});
test('table rules still apply to typed values',async()=>{
  await assert.rejects(db.query("insert into lwb_goods_inward(invoice_no,driver_name,driver_mobile) values('C1',$1,null)",['x'.repeat(101)]));
  await assert.rejects(db.query("insert into lwb_goods_inward(invoice_no,driver_name,driver_mobile) values('C2',null,'123')"));
  await db.query("insert into lwb_goods_inward(invoice_no,driver_name,driver_mobile) values('C3','',' ')");
});
