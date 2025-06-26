package main

import (
	"net/http"
	"sync"

	"github.com/gin-gonic/gin"
)

type Todo struct {
	ID   string `json:"id"`
	Task string `json:"task"`
}

var (
	store = map[string]Todo{}
	mu    = sync.Mutex{}
)

func main() {
	r := gin.Default()
	r.GET("/todos", func(c *gin.Context) {
		mu.Lock()
		defer mu.Unlock()
		list := make([]Todo, 0, len(store))
		for _, t := range store {
			list = append(list, t)
		}
		c.JSON(http.StatusOK, list)
	})
	r.POST("/todos", func(c *gin.Context) {
		var t Todo
		if err := c.ShouldBindJSON(&t); err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
			return
		}
		mu.Lock()
		store[t.ID] = t
		mu.Unlock()
		c.JSON(http.StatusCreated, t)
	})
	r.Run() // :8080
}
