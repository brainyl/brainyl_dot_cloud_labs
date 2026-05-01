-- Initialize database
CREATE DATABASE IF NOT EXISTS simpledb;

-- Create user (credentials will come from environment variables)
-- This is just a placeholder; actual user creation happens via env vars in Docker

USE simpledb;

-- Create items table
CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description VARCHAR(255),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX idx_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Insert sample data
INSERT INTO items (name, description) VALUES
    ('Sample Item 1', 'This is a sample item'),
    ('Sample Item 2', 'Another sample item'),
    ('Sample Item 3', 'Yet another sample item');
