// admin.js - Admin Portal Client logic
let token = localStorage.getItem("bilingual.admin.token") || "";
if (!token) {
  const readerToken = localStorage.getItem("bilingual.reader.token");
  const readerIsAdmin = localStorage.getItem("bilingual.reader.isAdmin") === "true";
  if (readerToken && readerIsAdmin) {
    token = readerToken;
    localStorage.setItem("bilingual.admin.token", token);
  }
}

const loginSection = document.getElementById("login-section");
const topbarSection = document.getElementById("topbar-section");
const adminSection = document.getElementById("admin-section");
const loginForm = document.getElementById("login-form");
const loginError = document.getElementById("login-error");
const logoutBtn = document.getElementById("logout-btn");

// Book Upload DOM elements
const progressBar = document.getElementById("progress-bar");
const progressContainer = document.getElementById("progress-container");
const uploadStatus = document.getElementById("upload-status");
const booksListBody = document.getElementById("books-list-body");

// API Keys DOM elements
const btnCreateApiKey = document.getElementById("btn-create-apikey");
const apikeyCreationBox = document.getElementById("apikey-creation-box");
const apikeyNameInput = document.getElementById("apikey-name");
const btnSubmitApiKey = document.getElementById("btn-submit-apikey");
const btnCancelApiKey = document.getElementById("btn-cancel-apikey");
const newKeyDisplay = document.getElementById("new-key-display");
const newKeyValue = document.getElementById("new-key-value");
const apikeysListBody = document.getElementById("apikeys-list-body");

// User & Permission DOM elements
const btnCreateUserToggle = document.getElementById("btn-create-user-toggle");
const userCreationBox = document.getElementById("user-creation-box");
const createUserForm = document.getElementById("create-user-form");
const btnCancelUser = document.getElementById("btn-cancel-user");
const selectUser = document.getElementById("select-user");
const selectBook = document.getElementById("select-book");
const btnGrantPermission = document.getElementById("btn-grant-permission");
const permissionsListBody = document.getElementById("permissions-list-body");

// --- API Calls Utility ---
async function apiCall(endpoint, method = "GET", body = null) {
  const headers = {
    "Content-Type": "application/json",
  };
  if (token) {
    headers["Authorization"] = `Bearer ${token}`;
  }

  const options = {
    method,
    headers,
  };
  if (body) {
    options.body = JSON.stringify(body);
  }

  let res = await fetch(endpoint, options);
  if (res.status === 401 && token) {
    // Access token expired, attempt silent refresh
    try {
      const refreshRes = await fetch("/api/auth/refresh", { method: "POST" });
      if (refreshRes.ok) {
        const refreshData = await refreshRes.json();
        token = refreshData.access_token;
        localStorage.setItem("bilingual.admin.token", token);
        localStorage.setItem("bilingual.reader.token", token);
        
        // Retry request with new token
        options.headers["Authorization"] = `Bearer ${token}`;
        res = await fetch(endpoint, options);
      } else {
        logout();
      }
    } catch (err) {
      logout();
    }
  }

  if (!res.ok) {
    if (res.status === 401 || res.status === 403) {
      logout();
    }
    const errData = await res.json().catch(() => ({}));
    throw new Error(errData.detail || "API request failed");
  }
  return res.json();
}

function showLogin() {
  loginSection.classList.remove("hidden");
  topbarSection.classList.add("hidden");
  adminSection.classList.add("hidden");
}

function showAdmin() {
  loginSection.classList.add("hidden");
  topbarSection.classList.remove("hidden");
  adminSection.classList.remove("hidden");
  loadDashboardData();
}

function logout() {
  token = "";
  localStorage.removeItem("bilingual.admin.token");
  localStorage.removeItem("bilingual.reader.token");
  localStorage.removeItem("bilingual.reader.isAdmin");
  fetch("/api/auth/logout", { method: "POST" });
  showLogin();
}

// Tab Switching Logic
window.switchTab = function(tabId) {
  // Toggle Active Buttons
  document.querySelectorAll(".tab-btn").forEach(btn => {
    btn.classList.remove("active");
  });
  const activeBtn = document.querySelector(`button[onclick="switchTab('${tabId}')"]`);
  if (activeBtn) activeBtn.classList.add("active");

  // Toggle Tab Contents
  document.querySelectorAll(".tab-content").forEach(content => {
    content.classList.remove("active");
  });
  const activeContent = document.getElementById(tabId);
  if (activeContent) activeContent.classList.add("active");
};

// --- Authentication Listeners ---
loginForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  loginError.classList.add("hidden");
  const username = loginForm.username.value;
  const password = loginForm.password.value;

  try {
    const data = await apiCall(`/api/auth/login?username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`, "POST");
    if (data.is_admin) {
      token = data.access_token;
      localStorage.setItem("bilingual.admin.token", token);
      localStorage.setItem("bilingual.reader.token", token);
      localStorage.setItem("bilingual.reader.isAdmin", "true");
      showAdmin();
    } else {
      loginError.textContent = "Lỗi: Bạn không có quyền Administrator.";
      loginError.classList.remove("hidden");
    }
  } catch (err) {
    loginError.textContent = err.message || "Đăng nhập thất bại.";
    loginError.classList.remove("hidden");
  }
});

logoutBtn.addEventListener("click", (e) => {
  e.preventDefault();
  logout();
});

// --- Dashboard Loading ---
let usersList = [];
let booksList = [];

async function loadDashboardData() {
  try {
    // 1. Fetch Books
    booksList = await apiCall("/api/books");
    renderBooksList(booksList);
    renderBooksDropdown(booksList);

    // 2. Fetch Users
    usersList = await apiCall("/api/admin/users");
    renderUsersDropdown(usersList);

    // 3. Fetch Permissions
    const permissions = await apiCall("/api/admin/permissions");
    renderPermissionsTable(permissions);

    // 4. Fetch API Keys
    const apikeys = await apiCall("/api/admin/apikeys");
    renderApiKeysTable(apikeys);
  } catch (err) {
    console.error("Dashboard error:", err);
  }
}

// --- Book Management Actions ---
function renderBooksList(books) {
  booksListBody.innerHTML = "";
  if (books.length === 0) {
    booksListBody.innerHTML = `<tr><td colspan="5" style="text-align: center; color: var(--text-muted);">Không có cuốn sách nào trong hệ thống.</td></tr>`;
    return;
  }

  books.forEach(b => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>
        <div class="cover-preview">
          ${b.cover ? `<img src="${b.cover}" alt="cover" />` : 'No Cover'}
        </div>
      </td>
      <td>
        <div style="font-weight: 700; color: #f3f4f6;">${b.title}</div>
        <div style="font-size: 0.8rem; color: var(--text-muted); margin-top: 0.25rem;">Tác giả: ${b.author || 'Unknown'}</div>
      </td>
      <td style="font-family: monospace; font-size: 0.85rem; color: #a5b4fc;">${b.slug}</td>
      <td>${b.pageCount} trang</td>
      <td>
        <div style="display: flex; gap: 0.5rem; justify-content: center;">
          <button class="btn btn-secondary btn-sm" onclick="downloadBook('${b.slug}')">Tải về (.bkb)</button>
          <button class="btn btn-danger btn-sm" onclick="deleteBook('${b.slug}', '${b.title}')">Xóa sách</button>
        </div>
      </td>
    `;
    booksListBody.appendChild(tr);
  });
}

window.downloadBook = function(slug) {
  // Simple download trigger utilizing the JWT authorization
  const downloadUrl = `/api/books/${slug}/download?token=${encodeURIComponent(token)}`;
  window.location.href = downloadUrl;
};

window.deleteBook = async function(slug, title) {
  if (!confirm(`Cảnh báo: Bạn có chắc muốn xóa vĩnh viễn cuốn sách "${title}" (${slug})?\nHành động này sẽ xóa file vật lý và tất cả highlight liên quan.`)) return;
  
  try {
    await apiCall(`/api/books/${slug}`, "DELETE");
    loadDashboardData();
  } catch (err) {
    alert("Xóa sách thất bại: " + err.message);
  }
};

// Handle Drag-and-Drop and File Uploader
window.handleBkbUpload = function(file) {
  if (!file) return;
  if (!file.name.endsWith(".bkb")) {
    alert("Vui lòng tải lên đúng định dạng file .bkb");
    return;
  }

  progressContainer.style.display = "block";
  progressBar.style.width = "0%";
  uploadStatus.style.color = "var(--text-muted)";
  uploadStatus.textContent = "Đang chuẩn bị tải lên...";

  const formData = new FormData();
  formData.append("file", file);

  const xhr = new XMLHttpRequest();
  xhr.open("POST", "/api/books/upload", true);
  
  // Set Auth headers
  if (token) {
    xhr.setRequestHeader("Authorization", `Bearer ${token}`);
  }

  // Upload Progress Listener
  xhr.upload.addEventListener("progress", (e) => {
    if (e.lengthComputable) {
      const percent = Math.round((e.loaded / e.total) * 100);
      progressBar.style.width = `${percent}%`;
      uploadStatus.textContent = `Đang tải lên: ${percent}%`;
    }
  });

  // Response Handler
  xhr.onload = () => {
    if (xhr.status === 200) {
      const res = JSON.parse(xhr.responseText);
      uploadStatus.style.color = "var(--success)";
      uploadStatus.textContent = res.message || "Tải lên và nạp sách thành công!";
      progressBar.style.width = "100%";
      setTimeout(() => {
        progressContainer.style.display = "none";
        uploadStatus.textContent = "";
      }, 3000);
      loadDashboardData();
    } else {
      let errDetail = "Tải lên thất bại";
      try {
        const errJson = JSON.parse(xhr.responseText);
        errDetail = errJson.detail || errDetail;
      } catch(err) {}
      uploadStatus.style.color = "var(--danger)";
      uploadStatus.textContent = "Lỗi: " + errDetail;
    }
  };

  xhr.onerror = () => {
    uploadStatus.style.color = "var(--danger)";
    uploadStatus.textContent = "Không thể kết nối với máy chủ.";
  };

  xhr.send(formData);
};

// Drag and drop zone events
const dropZone = document.querySelector(".upload-zone");
if (dropZone) {
  ['dragenter', 'dragover'].forEach(eventName => {
    dropZone.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropZone.style.borderColor = "var(--accent)";
      dropZone.style.background = "rgba(99, 102, 241, 0.08)";
    }, false);
  });

  ['dragleave', 'drop'].forEach(eventName => {
    dropZone.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropZone.style.borderColor = "rgba(99, 102, 241, 0.3)";
      dropZone.style.background = "rgba(99, 102, 241, 0.02)";
    }, false);
  });

  dropZone.addEventListener('drop', (e) => {
    const dt = e.dataTransfer;
    const files = dt.files;
    if (files.length > 0) {
      handleBkbUpload(files[0]);
    }
  }, false);
}

// --- Users & Permissions Management Actions ---
btnCreateUserToggle.addEventListener("click", () => {
  userCreationBox.classList.toggle("hidden");
  createUserForm.reset();
});

btnCancelUser.addEventListener("click", () => {
  userCreationBox.classList.add("hidden");
});

createUserForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const username = createUserForm.elements["new-username"].value.trim();
  const password = createUserForm.elements["new-password"].value.trim();

  try {
    await apiCall(`/api/auth/register?username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`, "POST");
    alert("Đã tạo tài khoản thành công!");
    userCreationBox.classList.add("hidden");
    loadDashboardData();
  } catch (err) {
    alert("Lỗi tạo người dùng: " + err.message);
  }
});

function renderUsersDropdown(users) {
  selectUser.innerHTML = "";
  users.forEach(u => {
    if (!u.is_admin) {
      const opt = document.createElement("option");
      opt.value = u.id;
      opt.textContent = u.username;
      selectUser.appendChild(opt);
    }
  });
}

function renderBooksDropdown(books) {
  selectBook.innerHTML = "";
  books.forEach(b => {
    const opt = document.createElement("option");
    opt.value = b.slug;
    opt.textContent = b.title;
    selectBook.appendChild(opt);
  });
}

btnGrantPermission.addEventListener("click", async () => {
  const userId = selectUser.value;
  const bookSlug = selectBook.value;
  if (!userId || !bookSlug) return alert("Vui lòng chọn người dùng và cuốn sách");

  try {
    await apiCall(`/api/admin/permissions?user_id=${userId}&book_slug=${encodeURIComponent(bookSlug)}`, "POST");
    loadDashboardData();
  } catch (err) {
    alert("Cấp quyền đọc sách thất bại: " + err.message);
  }
});

function renderPermissionsTable(permissions) {
  permissionsListBody.innerHTML = "";
  if (permissions.length === 0) {
    permissionsListBody.innerHTML = `<tr><td colspan="3" style="text-align: center; color: var(--text-muted);">Chưa có quyền đọc sách nào được cấp.</td></tr>`;
    return;
  }

  permissions.forEach(p => {
    const user = usersList.find(u => u.id === p.user_id);
    const book = booksList.find(b => b.slug === p.book_slug);
    const username = user ? user.username : `User ID ${p.user_id}`;
    const bookTitle = book ? book.title : p.book_slug;

    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td style="font-weight: 700;">${username}</td>
      <td>${bookTitle}</td>
      <td>
        <div style="text-align: center;">
          <button class="btn btn-danger btn-sm" onclick="revokePermission(${p.id})">Thu hồi quyền</button>
        </div>
      </td>
    `;
    permissionsListBody.appendChild(tr);
  });
}

window.revokePermission = async function(id) {
  if (!confirm("Bạn có chắc muốn thu hồi quyền truy cập này của người dùng?")) return;
  try {
    await apiCall(`/api/admin/permissions/${id}`, "DELETE");
    loadDashboardData();
  } catch (err) {
    alert("Thu hồi quyền thất bại: " + err.message);
  }
};

// --- API Keys Management Actions ---
btnCreateApiKey.addEventListener("click", () => {
  apikeyCreationBox.classList.remove("hidden");
  newKeyDisplay.classList.add("hidden");
  apikeyNameInput.value = "";
});

btnCancelApiKey.addEventListener("click", () => {
  apikeyCreationBox.classList.add("hidden");
});

btnSubmitApiKey.addEventListener("click", async () => {
  const name = apikeyNameInput.value.trim();
  if (!name) return alert("Vui lòng nhập tên nhãn API Key");

  try {
    const res = await apiCall(`/api/admin/apikeys?name=${encodeURIComponent(name)}`, "POST");
    newKeyValue.textContent = res.key_value;
    newKeyDisplay.classList.remove("hidden");
    
    // Reload API Keys
    const apikeys = await apiCall("/api/admin/apikeys");
    renderApiKeysTable(apikeys);
  } catch (err) {
    alert("Lỗi khi tạo API Key: " + err.message);
  }
});

function renderApiKeysTable(apikeys) {
  apikeysListBody.innerHTML = "";
  if (apikeys.length === 0) {
    apikeysListBody.innerHTML = `<tr><td colspan="4" style="text-align: center; color: var(--text-muted);">Chưa có API Key nào được tạo.</td></tr>`;
    return;
  }

  apikeys.forEach(k => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>${k.name}</td>
      <td style="font-family: monospace;">${k.key_value.slice(0, 15)}...</td>
      <td>
        <span class="badge ${k.is_active ? 'badge-success' : 'badge-danger'}">
          ${k.is_active ? 'Đang hoạt động' : 'Đã thu hồi'}
        </span>
      </td>
      <td>
        <div style="text-align: center;">
          ${k.is_active ? `<button class="btn btn-danger btn-sm" onclick="revokeKey(${k.id})">Vô hiệu hóa</button>` : '—'}
        </div>
      </td>
    `;
    apikeysListBody.appendChild(tr);
  });
}

window.revokeKey = async function(id) {
  if (!confirm("Vô hiệu hóa API Key này? Tất cả các CLI/Worker đang dùng Key này sẽ bị mất kết nối.")) return;
  try {
    await apiCall(`/api/admin/apikeys/${id}`, "DELETE");
    loadDashboardData();
  } catch (err) {
    alert("Thu hồi API Key thất bại: " + err.message);
  }
};

// --- Initial Session Check ---
if (token) {
  apiCall("/api/auth/me")
    .then(user => {
      if (user.is_admin) {
        showAdmin();
      } else {
        logout();
      }
    })
    .catch(() => {
      logout();
    });
} else {
  showLogin();
}
