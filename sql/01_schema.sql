-- =====================================================================
-- 01_schema.sql  |  E-Commerce Analytics Database (MySQL 8.0+)
-- =====================================================================
DROP DATABASE IF EXISTS shopsphere;
CREATE DATABASE shopsphere CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE shopsphere;

CREATE TABLE categories (
    category_id   INT PRIMARY KEY AUTO_INCREMENT,
    category_name VARCHAR(50) NOT NULL UNIQUE
);

CREATE TABLE products (
    product_id   INT PRIMARY KEY AUTO_INCREMENT,
    product_name VARCHAR(100) NOT NULL,
    category_id  INT NOT NULL,
    unit_price   DECIMAL(10,2) NOT NULL CHECK (unit_price > 0),
    unit_cost    DECIMAL(10,2) NOT NULL CHECK (unit_cost > 0),
    FOREIGN KEY (category_id) REFERENCES categories(category_id)
);

CREATE TABLE customers (
    customer_id  INT PRIMARY KEY AUTO_INCREMENT,
    first_name   VARCHAR(50) NOT NULL,
    last_name    VARCHAR(50) NOT NULL,
    email        VARCHAR(120) NOT NULL UNIQUE,
    city         VARCHAR(50) NOT NULL,
    signup_date  DATE NOT NULL,
    channel      ENUM('Organic','Paid Search','Social','Email','Referral') NOT NULL
);

CREATE TABLE orders (
    order_id     INT PRIMARY KEY AUTO_INCREMENT,
    customer_id  INT NOT NULL,
    order_date   DATE NOT NULL,
    status       ENUM('completed','cancelled','returned') NOT NULL,
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id),
    INDEX idx_orders_date (order_date),
    INDEX idx_orders_customer (customer_id)
);

CREATE TABLE order_items (
    order_item_id INT PRIMARY KEY AUTO_INCREMENT,
    order_id      INT NOT NULL,
    product_id    INT NOT NULL,
    quantity      INT NOT NULL CHECK (quantity > 0),
    unit_price    DECIMAL(10,2) NOT NULL,
    discount_pct  DECIMAL(5,2) NOT NULL DEFAULT 0,
    FOREIGN KEY (order_id)   REFERENCES orders(order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id),
    INDEX idx_items_order (order_id),
    INDEX idx_items_product (product_id)
);
