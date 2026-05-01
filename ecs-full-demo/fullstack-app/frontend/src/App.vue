<template>
  <div id="app">
    <header>
      <h1>Simple Item Manager</h1>
    </header>

    <main>
      <section class="add-item">
        <h2>Add New Item</h2>
        <form @submit.prevent="addItem">
          <input 
            v-model="newItem.name" 
            type="text" 
            placeholder="Item name" 
            required 
          />
          <input 
            v-model="newItem.description" 
            type="text" 
            placeholder="Description" 
          />
          <button type="submit">Add Item</button>
        </form>
      </section>

      <section class="items-list">
        <h2>Items</h2>
        <div v-if="loading">Loading...</div>
        <div v-else-if="error" class="error">{{ error }}</div>
        <ul v-else-if="items.length">
          <li v-for="item in items" :key="item.id">
            <div class="item-content">
              <strong>{{ item.name }}</strong>
              <p>{{ item.description || 'No description' }}</p>
            </div>
            <button v-if="allowDelete" @click="deleteItem(item.id)" class="delete-btn">Delete</button>
          </li>
        </ul>
        <p v-else>No items yet. Add one above!</p>
      </section>
    </main>
  </div>
</template>

<script>
import axios from 'axios'

const API_URL = import.meta.env.VITE_API_URL || '/api'

// Read runtime config written by entrypoint.sh into window.__APP_CONFIG__.
// Falls back to false so delete is off by default in every environment.
const allowDelete = (window.__APP_CONFIG__?.ALLOW_DELETE ?? 'true') !== 'false'

export default {
  name: 'App',
  data() {
    return {
      items: [],
      newItem: {
        name: '',
        description: ''
      },
      loading: false,
      error: null,
      allowDelete
    }
  },
  mounted() {
    this.fetchItems()
  },
  methods: {
    async fetchItems() {
      this.loading = true
      this.error = null
      try {
        const response = await axios.get(`${API_URL}/items`)
        this.items = response.data
      } catch (err) {
        this.error = 'Failed to load items'
        console.error(err)
      } finally {
        this.loading = false
      }
    },
    async addItem() {
      if (!this.newItem.name.trim()) return
      
      try {
        await axios.post(`${API_URL}/items`, this.newItem)
        this.newItem = { name: '', description: '' }
        await this.fetchItems()
      } catch (err) {
        this.error = 'Failed to add item'
        console.error(err)
      }
    },
    async deleteItem(id) {
      try {
        await axios.delete(`${API_URL}/items/${id}`)
        await this.fetchItems()
      } catch (err) {
        this.error = 'Failed to delete item'
        console.error(err)
      }
    }
  }
}
</script>

<style>
* {
  margin: 0;
  padding: 0;
  box-sizing: border-box;
}

body {
  font-family: Arial, sans-serif;
  background: #f5f5f5;
}

#app {
  max-width: 800px;
  margin: 0 auto;
  padding: 20px;
}

header {
  background: #42b983;
  color: white;
  padding: 20px;
  border-radius: 8px;
  margin-bottom: 30px;
  text-align: center;
}

main {
  display: flex;
  flex-direction: column;
  gap: 30px;
}

section {
  background: white;
  padding: 20px;
  border-radius: 8px;
  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
}

h2 {
  margin-bottom: 15px;
  color: #333;
}

form {
  display: flex;
  gap: 10px;
  flex-wrap: wrap;
}

input {
  flex: 1;
  min-width: 200px;
  padding: 10px;
  border: 1px solid #ddd;
  border-radius: 4px;
  font-size: 14px;
}

button {
  padding: 10px 20px;
  background: #42b983;
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  font-size: 14px;
}

button:hover {
  background: #359268;
}

ul {
  list-style: none;
}

li {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 15px;
  border-bottom: 1px solid #eee;
}

li:last-child {
  border-bottom: none;
}

.item-content {
  flex: 1;
}

.item-content p {
  color: #666;
  margin-top: 5px;
  font-size: 14px;
}

.delete-btn {
  background: #e74c3c;
  padding: 8px 15px;
}

.delete-btn:hover {
  background: #c0392b;
}

.error {
  color: #e74c3c;
  padding: 10px;
  background: #fee;
  border-radius: 4px;
}
</style>
