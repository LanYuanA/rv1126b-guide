import DefaultTheme from 'vitepress/theme'
import Sdk from './Sdk.vue'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('Sdk', Sdk)
  },
}
