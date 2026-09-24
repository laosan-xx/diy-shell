import { createRouter, createWebHashHistory } from 'vue-router'
import HomeView from '../views/HomeView.vue'
import ToolView from '../views/ToolView.vue'

const routes = [
  { path: '/', name: 'home', component: HomeView },
  { path: '/tool/:id', name: 'tool', component: ToolView, props: true },
]

// 使用 hash 路由，静态部署无需额外服务器重写规则
export default createRouter({
  history: createWebHashHistory(),
  routes,
})
