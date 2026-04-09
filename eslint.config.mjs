import eslint from '@eslint/js'
import eslintPluginPrettierRecommended from 'eslint-plugin-prettier/recommended'
import { defineConfig } from 'eslint/config'
import tseslint from 'typescript-eslint'

const prettierOptions = {
  printWidth: 80,
  bracketSpacing: true,
  singleQuote: true,
  semi: false,
  trailingComma: 'es5',
  endOfLine: 'auto',
}

export default defineConfig(
  {
    ignores: ['node_modules/**', 'build/**'],
  },
  eslint.configs.recommended,
  tseslint.configs.recommended,
  eslintPluginPrettierRecommended,
  {
    files: ['src/**/*.ts', 'src/**/*.tsx'],
    rules: {
      // Single quotes: use Prettier (typescript-eslint v8 removed @typescript-eslint/quotes).
      indent: 'off',
      'linebreak-style': 0,
      'object-curly-spacing': ['error', 'always'],
      semi: 'off',
      'space-infix-ops': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_' },
      ],
      'prettier/prettier': ['error', prettierOptions],
    },
  },
  {
    files: ['eslint.config.mjs', '*.config.mjs'],
    rules: {
      semi: 'off',
      'prettier/prettier': ['error', prettierOptions],
    },
    ignores: ['example/**'],
  }
)
