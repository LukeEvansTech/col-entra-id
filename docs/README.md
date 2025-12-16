# Documentation

This directory contains the documentation site for Entra ID User Lifecycle Management.

## Building Locally

1. Install Zensical:
   ```bash
   pip install zensical
   ```

2. Serve locally:
   ```bash
   cd docs
   zensical serve
   ```

3. Build static site:
   ```bash
   zensical build
   ```

## Structure

```
docs/
├── docs/               # Markdown source files
│   ├── index.md       # Home page
│   ├── setup.md       # Setup guide
│   ├── permissions.md # Permissions reference
│   ├── parameters.md  # Parameters reference
│   ├── runbooks.md    # Runbooks overview
│   └── stylesheets/   # Custom CSS
├── site/              # Built static site (gitignored)
├── zensical.toml      # Site configuration
└── requirements.txt   # Python dependencies
```
