import atexit
import os
from contextlib import contextmanager
from typing import Any
from flask import Flask, flash, redirect, render_template, request, url_for
import oracledb


app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "happy-weddings-development-key")
_pool: oracledb.ConnectionPool | None = None


def database_dsn() -> str:
	return (
		f"{os.getenv('ORACLE_HOST', 'localhost')}:"
		f"{os.getenv('ORACLE_PORT', '1521')}/"
		f"{os.getenv('ORACLE_SERVICE', 'XE')}"
	)


def get_pool() -> oracledb.ConnectionPool:
	global _pool
	if _pool is None:
		_pool = oracledb.create_pool(
			user=os.getenv("ORACLE_USER", "yellowcom"),
			password=os.getenv("ORACLE_PASSWORD", "yellowcom"),
			dsn=database_dsn(),
			min=1,
			max=5,
			increment=1,
		)
	return _pool


@contextmanager
def get_connection():
	connection = get_pool().acquire()
	try:
		yield connection
	finally:
		connection.close()


def close_pool() -> None:
	if _pool is not None:
		_pool.close()


atexit.register(close_pool)


def connection_status() -> dict[str, Any]:
	try:
		with get_connection() as connection:
			with connection.cursor() as cursor:
				cursor.execute(
					"SELECT USER, SYS_CONTEXT('USERENV', 'SERVICE_NAME') FROM DUAL"
				)
				user, service = cursor.fetchone()
		return {"connected": True, "user": user, "service": service}
	except oracledb.Error as error:
		return {"connected": False, "error": str(error)}


def fetch_catalog_data() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
	clients: list[dict[str, Any]] = []
	services: list[dict[str, Any]] = []
	with get_connection() as connection:
		with connection.cursor() as cursor:
			cursor.execute(
				"SELECT REFTOHEX(REF(c)), first_name, last_name, phone FROM Client c "
				"ORDER BY first_name, last_name"
			)
			clients = [
				{"ref": row[0], "first_name": row[1], "last_name": row[2], "phone": row[3]}
				for row in cursor
			]
			cursor.execute(
				"SELECT REFTOHEX(REF(s)), description, min_cost, max_cost, lead_time "
				"FROM Service s ORDER BY description"
			)
			services = [
				{"ref": row[0], "description": row[1], "min_cost": row[2], "max_cost": row[3], "lead_time": row[4]}
				for row in cursor
			]
	return clients, services


@app.get("/")
def dashboard():
	return render_template("dashboard.html", oracle=connection_status())


@app.route("/clients/new", methods=["GET", "POST"])
def new_client():
	if request.method == "POST":
		try:
			with get_connection() as connection:
				with connection.cursor() as cursor:
					cursor.callproc(
						"insert_new_client",
						[
							request.form["first_name"].strip(),
							request.form["last_name"].strip(),
							request.form["phone"].strip(),
						],
					)
				connection.commit()
			flash("Client inserted successfully.", "success")
			return redirect(url_for("new_client"))
		except oracledb.Error as error:
			flash(f"Could not insert client: {error}", "error")
	return render_template("client_form.html")


@app.route("/orders/new", methods=["GET", "POST"])
def new_order():
	try:
		clients, services = fetch_catalog_data()
	except oracledb.Error as error:
		flash(f"Catalog is unavailable: {error}", "error")
		clients, services = [], []
	if request.method == "POST":
		selected_services = request.form.getlist("service_refs")
		if not selected_services:
			flash("Select at least one service.", "error")
			return render_template("order_form.html", clients=clients, services=services)
		try:
			with get_connection() as connection:
				with connection.cursor() as cursor:
					binds = {f"service_{index}": value for index, value in enumerate(selected_services)}
					binds.update(client_ref=request.form["client_ref"], wedding_date=request.form["wedding_date"], filing_date=request.form["filing_date"])
					service_ref_statements = "".join(
						f"v_services.EXTEND;\nv_services({index + 1}) := HEXTOREF(:service_{index});\n"
						for index in range(len(selected_services))
					)
					cursor.execute(
						f"""DECLARE
							v_services ServiceRef_nt := ServiceRef_nt();
							v_client REF Client_ty := HEXTOREF(:client_ref);
						BEGIN
							{service_ref_statements}
							insert_order_form(v_client, TO_DATE(:wedding_date, 'YYYY-MM-DD'), TO_DATE(:filing_date, 'YYYY-MM-DD'), v_services);
						END;""",
						binds,
					)
				connection.commit()
			flash("Order registered successfully.", "success")
			return redirect(url_for("new_order"))
		except oracledb.Error as error:
			flash(f"Could not register order: {error}", "error")
	return render_template("order_form.html", clients=clients, services=services)


@app.get("/clients/<client_ref>/services")
def client_services(client_ref: str):
	rows: list[dict[str, Any]] = []
	try:
		with get_connection() as connection:
			with connection.cursor() as cursor:
				cursor.execute(
					"""SELECT o.wedding_date, s.description, s.min_cost, s.max_cost,
						CASE
							WHEN VALUE(s) IS OF (Clothing_ty) THEN 'Clothing'
							WHEN VALUE(s) IS OF (WeddingRegistryStore_ty) THEN 'Wedding registry store'
							WHEN VALUE(s) IS OF (FlowerService_ty) THEN 'Flower service'
							WHEN VALUE(s) IS OF (Catering_ty) THEN 'Catering'
							ELSE 'Service'
						END AS category
					FROM OrderForm o, TABLE(o.requested_services) requested, Service s
					WHERE o.client_ref = HEXTOREF(:client_ref)
					AND REF(s) = requested.service_ref
					ORDER BY o.wedding_date, s.description""",
					{"client_ref": client_ref},
				)
				rows = [
					{"wedding_date": row[0], "description": row[1], "min_cost": row[2], "max_cost": row[3], "category": row[4]}
					for row in cursor
				]
	except oracledb.Error as error:
		flash(f"Could not read services: {error}", "error")
	return render_template("client_services.html", rows=rows)


@app.get("/services")
def services_lookup():
	try:
		clients, _ = fetch_catalog_data()
	except oracledb.Error as error:
		flash(f"Clients are unavailable: {error}", "error")
		clients = []
	return render_template("client_lookup.html", clients=clients)


@app.route("/catering", methods=["GET", "POST"])
def catering():
	services: list[dict[str, Any]] = []
	menus: list[dict[str, Any]] = []
	restaurant: dict[str, Any] | None = None
	try:
		with get_connection() as connection:
			with connection.cursor() as cursor:
				cursor.execute(
					"SELECT REFTOHEX(REF(s)), description FROM Service s "
					"WHERE VALUE(s) IS OF (Catering_ty) ORDER BY description"
				)
				services = [{"ref": row[0], "description": row[1]} for row in cursor]
				if request.method == "POST" and request.form.get("service_ref"):
					service_ref = request.form["service_ref"]
					cursor.execute(
						"SELECT DEREF(TREAT(VALUE(s) AS Catering_ty).restaurant_ref).name, "
						"DEREF(TREAT(VALUE(s) AS Catering_ty).restaurant_ref).address "
						"FROM Service s WHERE REF(s) = HEXTOREF(:service_ref)",
						{"service_ref": service_ref},
					)
					restaurant_row = cursor.fetchone()
					if restaurant_row:
						restaurant = {"name": restaurant_row[0], "address": restaurant_row[1]}
					cursor.execute(
						"SELECT m.dishes, m.wines "
						"FROM Service s, "
						"TABLE(TREAT(VALUE(s) AS Catering_ty).proposed_menus) proposed, Menu m "
						"WHERE REF(s) = HEXTOREF(:service_ref) AND REF(m) = proposed.menu_ref",
						{"service_ref": service_ref},
					)
					for dishes, wines in cursor:
						dish_items = [
							{"description": dish.DESCRIPTION, "dish_type": dish.DISH_TYPE}
							for dish in (dishes.aslist() if dishes is not None else [])
						]
						wine_items = [
							{"name": wine.NAME}
							for wine in (wines.aslist() if wines is not None else [])
						]
						menus.append({"dishes": dish_items, "wines": wine_items})
	except oracledb.Error as error:
		flash(f"Catering catalog is unavailable: {error}", "error")
	return render_template("catering.html", services=services, restaurant=restaurant, menus=menus)


if __name__ == "__main__":
	app.run(host="127.0.0.1", port=int(os.getenv("FLASK_PORT", "5000")), debug=False)
