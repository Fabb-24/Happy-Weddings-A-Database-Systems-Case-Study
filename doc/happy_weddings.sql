-- 1. Types and tables
 
-- Service
CREATE TYPE Service_ty AS OBJECT (
  description VARCHAR(50),
  min_cost    NUMBER(8,2),
  max_cost    NUMBER(8,2),
  lead_time   NUMBER
) NOT INSTANTIABLE NOT FINAL;
/
 
-- Clothing
CREATE TYPE Shoe_ty AS OBJECT (
  name VARCHAR(20)
);
/
 
CREATE TYPE Store_ty AS OBJECT (
  name VARCHAR(20)
);
/
 
CREATE TYPE ShoeList_ty AS VARRAY(20) OF Shoe_ty;
/
 
CREATE TYPE StoreList_ty AS VARRAY(20) OF Store_ty;
/
 
CREATE TYPE Accessory_ty AS OBJECT (
  material       VARCHAR(16),
  accessory_type VARCHAR(16),
  cost           NUMBER(8,2)
);
/
 
CREATE TABLE Accessory OF Accessory_ty;
 
CREATE TYPE AccessoryMatched_ty AS OBJECT (
  accessory_ref REF Accessory_ty
);
/
 
CREATE TYPE AccessoryMatched_nt AS TABLE OF AccessoryMatched_ty;
/
 
CREATE TYPE Clothing_ty UNDER Service_ty (
  color    VARCHAR(16),
  material VARCHAR(16),
  shoes    ShoeList_ty,
  stores   StoreList_ty
) NOT INSTANTIABLE NOT FINAL;
/
 
CREATE TYPE BridalClothing_ty UNDER Clothing_ty;
/
 
CREATE TYPE GroomClothing_ty UNDER Clothing_ty (
  accessories_matched AccessoryMatched_nt
);
/
 
-- Wedding Registry Store
CREATE TYPE WeddingRegistryStore_ty UNDER Service_ty (
  store_type  VARCHAR(16),
  address     VARCHAR(32),
  store_phone VARCHAR(16)
);
/
 
-- Flower Service
CREATE TYPE Flower_ty AS OBJECT (
  name        VARCHAR(32),
  shade       VARCHAR(16),
  start_month NUMBER(2),
  end_month   NUMBER(2)
);
/
 
CREATE TABLE Flower OF Flower_ty (
  CONSTRAINT uq_flower UNIQUE (name, shade)
);
 
CREATE TYPE ArrangementComposition_ty AS OBJECT (
  flower_ref REF Flower_ty
);
/
 
CREATE TYPE ArrangementComposition_nt AS TABLE OF ArrangementComposition_ty;
/
 
CREATE TYPE FlowerService_ty UNDER Service_ty (
  arrangement_type VARCHAR(32),
  flowers          ArrangementComposition_nt
);
/
 
-- Catering
CREATE TYPE Restaurant_ty AS OBJECT (
  name    VARCHAR(32),
  address VARCHAR(32)
);
/
 
CREATE TABLE Restaurant OF Restaurant_ty (
  CONSTRAINT uq_restaurant UNIQUE (name, address)
);
 
CREATE TYPE Dish_ty AS OBJECT (
  description VARCHAR(50),
  dish_type   VARCHAR(16)
);
/
 
CREATE TYPE Dish_nt AS TABLE OF Dish_ty;
/
 
CREATE TYPE Wine_ty AS OBJECT (
  name VARCHAR(32)
);
/
 
CREATE TYPE Wine_nt AS TABLE OF Wine_ty;
/
 
CREATE TYPE Menu_ty AS OBJECT (
  dishes Dish_nt,
  wines  Wine_nt
);
/
 
CREATE TABLE Menu OF Menu_ty
  NESTED TABLE dishes STORE AS dishes_store
  NESTED TABLE wines  STORE AS wines_store;
 
CREATE TYPE ProposedMenus_ty AS OBJECT (
  menu_ref REF Menu_ty
);
/
 
CREATE TYPE ProposedMenus_nt AS TABLE OF ProposedMenus_ty;
/
 
CREATE TYPE Catering_ty UNDER Service_ty (
  restaurant_ref REF Restaurant_ty,
  proposed_menus ProposedMenus_nt
);
/
 
-- Service table
CREATE TABLE Service OF Service_ty
  NESTED TABLE TREAT(SYS_NC_ROWINFO$ AS GroomClothing_ty).accessories_matched
    STORE AS accessories_matched_store
  NESTED TABLE TREAT(SYS_NC_ROWINFO$ AS FlowerService_ty).flowers
    STORE AS flowers_store
  NESTED TABLE TREAT(SYS_NC_ROWINFO$ AS Catering_ty).proposed_menus
    STORE AS proposed_menus_store;
 
ALTER TABLE accessories_matched_store
  ADD (SCOPE FOR (accessory_ref) IS Accessory);
 
ALTER TABLE flowers_store
  ADD (SCOPE FOR (flower_ref) IS Flower);
 
ALTER TABLE proposed_menus_store
  ADD (SCOPE FOR (menu_ref) IS Menu);
 
-- Client, Order Form and Invoice
CREATE TYPE Client_ty AS OBJECT (
  first_name VARCHAR(16),
  last_name  VARCHAR(16),
  phone      VARCHAR(16)
);
/
 
CREATE TABLE Client OF Client_ty (
  CONSTRAINT uq_client UNIQUE (first_name, last_name, phone)
);
 
CREATE TYPE RequestedServices_ty AS OBJECT (
  service_ref REF Service_ty
);
/
 
CREATE TYPE RequestedServices_nt AS TABLE OF RequestedServices_ty;
/
 
CREATE TYPE OrderForm_ty AS OBJECT (
  wedding_date       DATE,
  filing_date        DATE,
  client_ref         REF Client_ty,
  requested_services RequestedServices_nt
);
/
 
CREATE TYPE ProvidedServices_ty AS OBJECT (
  cost        NUMBER(8,2),
  service_ref REF Service_ty
);
/
 
CREATE TYPE ProvidedServices_nt AS TABLE OF ProvidedServices_ty;
/
 
CREATE TYPE Invoice_ty AS OBJECT (
  issue_date        DATE,
  wedding_date      DATE,
  payment_method    VARCHAR(32),
  client_ref        REF Client_ty,
  provided_services ProvidedServices_nt
);
/
 
CREATE TABLE OrderForm OF OrderForm_ty (
  SCOPE FOR (client_ref) IS Client
)
  NESTED TABLE requested_services STORE AS requested_services_store;
 
ALTER TABLE requested_services_store
  ADD (SCOPE FOR (service_ref) IS Service);
 
CREATE TABLE Invoice OF Invoice_ty (
  SCOPE FOR (client_ref) IS Client
)
  NESTED TABLE provided_services STORE AS provided_services_store;
 
ALTER TABLE provided_services_store
  ADD (SCOPE FOR (service_ref) IS Service);
 
 
-- 2. Check constraints
ALTER TABLE OrderForm
  ADD CONSTRAINT chk_orderform_dates
  CHECK (filing_date < wedding_date);
 
ALTER TABLE Invoice
  ADD CONSTRAINT chk_invoice_dates
  CHECK (issue_date >= wedding_date);
 
ALTER TABLE Service
  ADD CONSTRAINT chk_service_costs
  CHECK (min_cost <= max_cost);
 
ALTER TABLE Flower
  ADD CONSTRAINT chk_flower_period
  CHECK (start_month BETWEEN 1 AND 12 AND end_month BETWEEN 1 AND 12);
 
ALTER TABLE dishes_store
  ADD CONSTRAINT chk_dish_type
  CHECK (dish_type IN ('appetizer', 'first course', 'second course', 'dessert'));
 
 
-- 3. Triggers
 
CREATE OR REPLACE TRIGGER trg_orderform_leadtime
BEFORE INSERT OR UPDATE ON OrderForm
FOR EACH ROW
DECLARE
  v_available NUMBER;
  v_service   Service_ty;
BEGIN
  v_available := :NEW.wedding_date - :NEW.filing_date;
  IF :NEW.requested_services IS NOT NULL THEN
    FOR i IN 1 .. :NEW.requested_services.COUNT LOOP
      SELECT DEREF(:NEW.requested_services(i).service_ref)
      INTO   v_service
      FROM   DUAL;
      IF v_available < v_service.lead_time THEN
        RAISE_APPLICATION_ERROR(-20002,
          'The interval between filing date and wedding date is shorter than the lead time of one of the requested services.');
      END IF;
    END LOOP;
  END IF;
END;
/
 
CREATE OR REPLACE TRIGGER trg_invoice_finalcost
BEFORE INSERT OR UPDATE ON Invoice
FOR EACH ROW
DECLARE
  v_service Service_ty;
BEGIN
  IF :NEW.provided_services IS NOT NULL THEN
    FOR i IN 1 .. :NEW.provided_services.COUNT LOOP
      SELECT DEREF(:NEW.provided_services(i).service_ref)
      INTO   v_service
      FROM   DUAL;
      IF :NEW.provided_services(i).cost < v_service.min_cost
         OR :NEW.provided_services(i).cost > v_service.max_cost THEN
        RAISE_APPLICATION_ERROR(-20003,
          'The final cost of a provided service must fall between its minimum and maximum cost.');
      END IF;
    END LOOP;
  END IF;
END;
/
 
CREATE OR REPLACE TRIGGER trg_invoice_wedding_exists
BEFORE INSERT OR UPDATE ON Invoice
FOR EACH ROW
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*)
  INTO   v_count
  FROM   OrderForm o
  WHERE  o.client_ref   = :NEW.client_ref
  AND    o.wedding_date = :NEW.wedding_date;
 
  IF v_count = 0 THEN
    RAISE_APPLICATION_ERROR(-20001,
      'The wedding date of the invoice does not match any order form of the client.');
  END IF;
END;
/
 
 
-- 4. Procedures
 
CREATE OR REPLACE PROCEDURE insert_new_client (
  p_first_name IN VARCHAR,
  p_last_name  IN VARCHAR,
  p_phone      IN VARCHAR
) IS
BEGIN
  INSERT INTO Client
  VALUES (Client_ty(p_first_name, p_last_name, p_phone));
END insert_new_client;
/
 
CREATE OR REPLACE TYPE ServiceRef_nt AS TABLE OF REF Service_ty;
/
 
CREATE OR REPLACE PROCEDURE insert_order_form (
  p_client_ref   IN REF Client_ty,
  p_wedding_date IN DATE,
  p_filing_date  IN DATE,
  p_service_refs IN ServiceRef_nt
) IS
  v_requested_services RequestedServices_nt := RequestedServices_nt();
BEGIN
  FOR i IN 1 .. p_service_refs.COUNT LOOP
    v_requested_services.EXTEND;
    v_requested_services(i) := RequestedServices_ty(p_service_refs(i));
  END LOOP;
 
  INSERT INTO OrderForm
  VALUES (
    OrderForm_ty(
      p_wedding_date,
      p_filing_date,
      p_client_ref,
      v_requested_services
    )
  );
END insert_order_form;
/
 
CREATE OR REPLACE PROCEDURE print_catering_details (
  p_service_ref IN REF Service_ty
) IS
  v_catering   Catering_ty;
  v_restaurant Restaurant_ty;
  v_menu       Menu_ty;
BEGIN
  SELECT TREAT(DEREF(p_service_ref) AS Catering_ty)
  INTO   v_catering
  FROM   DUAL;
 
  IF v_catering IS NULL THEN
    RAISE_APPLICATION_ERROR(-20010, 'The given service is not a catering service.');
  END IF;
 
  SELECT DEREF(v_catering.restaurant_ref)
  INTO   v_restaurant
  FROM   DUAL;
 
  DBMS_OUTPUT.PUT_LINE('Restaurant: ' || v_restaurant.name || ', ' || v_restaurant.address);
 
  IF v_catering.proposed_menus IS NOT NULL THEN
    FOR i IN 1 .. v_catering.proposed_menus.COUNT LOOP
      SELECT DEREF(v_catering.proposed_menus(i).menu_ref)
      INTO   v_menu
      FROM   DUAL;
 
      DBMS_OUTPUT.PUT_LINE('--- Menu ---');
 
      IF v_menu.dishes IS NOT NULL THEN
        FOR d IN 1 .. v_menu.dishes.COUNT LOOP
          DBMS_OUTPUT.PUT_LINE('Dish: ' || v_menu.dishes(d).description
                               || ' (' || v_menu.dishes(d).dish_type || ')');
        END LOOP;
      END IF;
 
      IF v_menu.wines IS NOT NULL THEN
        FOR w IN 1 .. v_menu.wines.COUNT LOOP
          DBMS_OUTPUT.PUT_LINE('Wine: ' || v_menu.wines(w).name);
        END LOOP;
      END IF;
    END LOOP;
  END IF;
END print_catering_details;
/
 
CREATE OR REPLACE PROCEDURE print_client_services (
  p_client_ref IN REF Client_ty
) IS
BEGIN
  FOR rec IN (
    SELECT s.description, s.min_cost, s.max_cost,
           CASE
             WHEN VALUE(s) IS OF (Clothing_ty)             THEN 'Clothing'
             WHEN VALUE(s) IS OF (WeddingRegistryStore_ty) THEN 'Wedding Registry Store'
             WHEN VALUE(s) IS OF (FlowerService_ty)        THEN 'Flower Service'
             WHEN VALUE(s) IS OF (Catering_ty)             THEN 'Catering'
             ELSE 'Unknown'
           END AS category
    FROM   OrderForm o, TABLE(o.requested_services) r, Service s
    WHERE  o.client_ref = p_client_ref
    AND    REF(s) = r.service_ref
  ) LOOP
    DBMS_OUTPUT.PUT_LINE(
      'Service: '     || rec.description
      || ', Min Cost: ' || rec.min_cost
      || ', Max Cost: ' || rec.max_cost
      || ', Category: ' || rec.category
    );
  END LOOP;
END print_client_services;
/
 
 
-- 5. Indexes
CREATE INDEX idx_orderform_client_ref ON OrderForm (client_ref);
