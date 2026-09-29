-- █ marks the cursor. `history` lists recent edits, oldest first.
return {
  {
    name = "go-after-call",
    kind = "fim",
    path = "store/user.go",
    text = [[
package store

import (
	"context"
	"database/sql"
	"fmt"
)

type User struct {
	ID    int64
	Name  string
	Email string
}

type Store struct {
	db *sql.DB
}

func (s *Store) UserByEmail(ctx context.Context, email string) (*User, error) {
	var u User
	err := s.db.QueryRowContext(ctx, "SELECT id, name, email FROM users WHERE email = ?", email).Scan(&u.ID, &u.Name, &u.Email)
	█
}

func (s *Store) DeleteUser(ctx context.Context, id int64) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM users WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("delete user %d: %w", id, err)
	}
	return nil
}
]],
  },
  {
    name = "go-midline",
    kind = "fim",
    path = "api/handler.go",
    text = [[
package api

import (
	"encoding/json"
	"net/http"
)

type healthResponse struct {
	Status  string `json:"status"`
	Version string `json:"version"`
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	resp := healthResponse{Status: "ok", Version: a.version}
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(█); err != nil {
		a.log.Error("encode health", "err", err)
	}
}
]],
  },
  {
    name = "go-comment",
    kind = "fim",
    path = "retry/retry.go",
    text = [[
package retry

import (
	"context"
	"time"
)

// Retry calls fn until it succeeds or █
func Retry(ctx context.Context, attempts int, delay time.Duration, fn func() error) error {
	var err error
	for range attempts {
		if err = fn(); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return err
}
]],
  },
  {
    name = "lua-keymaps",
    kind = "fim",
    path = "lua/config/keymaps.lua",
    text = [[
local builtin = require("telescope.builtin")

vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find files" })
vim.keymap.set("n", "<leader>fg", builtin.live_grep, { desc = "Live grep" })
vim.keymap.set("n", "<leader>fb", █
]],
  },
  {
    name = "md-prose",
    kind = "fim",
    path = "README.md",
    text = [[
# tsugi.nvim

Fast local code completion and next edit suggestions for Neovim.

## Installation

Install with lazy.nvim:

```lua
{ "mizuchilabs/tsugi.nvim", opts = {} }
```

tsugi talks to a llama.cpp server. █

## Configuration
]],
  },
  {
    name = "nes-rename-param",
    kind = "nes",
    path = "server/server.go",
    text = [[
package server

import (
	"log/slog"
	"net/http"
)

type Server struct {
	srv *http.Server
	log *slog.Logger
	cfg Config
}

func New(config Config, logger *slog.Logger) *Server {
	█mux := http.NewServeMux()
	srv := &http.Server{
		Addr:         cfg.Addr,
		ReadTimeout:  cfg.ReadTimeout,
		WriteTimeout: cfg.WriteTimeout,
		Handler:      mux,
	}
	return &Server{srv: srv, log: logger, cfg: cfg}
}
]],
    history = {
      {
        path = "server/server.go",
        start = 14,
        old = "func New(cfg Config, logger *slog.Logger) *Server {",
        new = "func New(config Config, logger *slog.Logger) *Server {",
      },
    },
  },
  {
    name = "nes-add-arg",
    kind = "nes",
    path = "api/user.go",
    text = [[
package api

import (
	"context"
	"net/http"
	"strconv"
)

func fetchUser(ctx context.Context, █id int64) (*User, error) {
	return nil, nil
}

func (a *API) user(w http.ResponseWriter, r *http.Request) {
	id, _ := strconv.ParseInt(r.PathValue("id"), 10, 64)
	u, err := fetchUser(id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	a.json(w, u)
}
]],
    history = {
      {
        path = "api/user.go",
        start = 9,
        old = "func fetchUser(id int64) (*User, error) {",
        new = "func fetchUser(ctx context.Context, id int64) (*User, error) {",
      },
    },
  },
  {
    name = "nes-quiet",
    kind = "nes",
    path = "store/user.go",
    text = [[
package store

func (s *Store) DeleteUser(ctx context.Context, id int64) error {
	_, err := s.db.ExecContext(ctx, "DELETE FROM users WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("delete user %d: %w", id, err)
	}
	return nil█
}
]],
    history = {
      {
        path = "store/user.go",
        start = 8,
        old = "",
        new = "\treturn nil",
      },
    },
  },
}
