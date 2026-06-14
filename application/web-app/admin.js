// admin.js - Professional Admin Portal Client logic
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

// --- Custom Toast Notifications ---
function showToast(message, type = "info") {
  const container = document.getElementById("toast-container");
  if (!container) return;

  const toast = document.createElement("div");
  toast.className = `toast toast-${type}`;
  
  let icon = "";
  if (type === "success") {
    icon = `<svg style="width:18px;height:18px;fill:var(--success)" viewBox="0 0 24 24"><path d="M12 2C6.5 2 2 6.5 2 12S6.5 22 12 22 22 17.5 22 12 17.5 2 12 2M10 17L5 12L6.41 10.59L10 14.17L17.59 6.58L19 8L10 17Z"/></svg>`;
  } else if (type === "danger") {
    icon = `<svg style="width:18px;height:18px;fill:var(--danger)" viewBox="0 0 24 24"><path d="M12 2C6.5 2 2 6.5 2 12S6.5 22 12 22 22 17.5 22 12 17.5 2 12 2M13 17H11V15H13V17M13 13H11V7H13V13Z"/></svg>`;
  } else {
    icon = `<svg style="width:18px;height:18px;fill:var(--primary)" viewBox="0 0 24 24"><path d="M11,9H13V7H11M12,20C7.59,20 4,16.41 4,12C4,7.59 7.59,4 12,4C16.41,4 20,7.59 20,12C20,16.41 16.41,20 12,20M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M11,17H13V11H11V17Z"/></svg>`;
  }

  // Ensure border colors match standard theme
  if (type === 'success') toast.style.borderLeft = '4px solid var(--success)';
  if (type === 'danger') toast.style.borderLeft = '4px solid var(--danger)';
  if (type === 'info') toast.style.borderLeft = '4px solid var(--primary)';

  toast.innerHTML = `
    ${icon}
    <div style="font-weight: 500; font-size: 0.8125rem;">${message}</div>
  `;

  container.appendChild(toast);
  
  // Trigger animation reflow
  setTimeout(() => {
    toast.classList.add("show");
  }, 10);

  // Auto remove
  setTimeout(() => {
    toast.classList.remove("show");
    setTimeout(() => {
      toast.remove();
    }, 300);
  }, 3500);
}

// Custom Confirmation Modal
window.showConfirm = function(message, title = "Xác nhận") {
  return new Promise((resolve) => {
    const modal = document.getElementById("custom-confirm-modal");
    const titleEl = document.getElementById("confirm-title");
    const msgEl = document.getElementById("confirm-message");
    const okBtn = document.getElementById("confirm-ok-btn");

    titleEl.textContent = title;
    msgEl.innerHTML = message;
    modal.classList.add("show");

    const cleanUp = () => {
      modal.classList.remove("show");
      okBtn.onclick = null;
    };

    okBtn.onclick = () => {
      cleanUp();
      resolve(true);
    };

    window.closeConfirmModal = (result) => {
      cleanUp();
      resolve(result);
    };
  });
};

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
    throw new Error(errData.detail || "Yêu cầu API thất bại");
  }
  return res.json();
}

function showLogin() {
  loginSection.classList.remove("hidden");
  adminSection.classList.add("hidden");
}

function showAdmin() {
  loginSection.classList.add("hidden");
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
  showToast("Bạn đã đăng xuất hệ thống", "info");
}

// Tab Switching Logic
window.switchTab = function(tabId, tabName) {
  // Update Topbar Title
  const titleEl = document.getElementById('current-page-title');
  if (titleEl && tabName) {
    titleEl.textContent = tabName;
  }

  // Toggle Active Buttons
  document.querySelectorAll(".nav-item").forEach(btn => {
    btn.classList.remove("active");
  });
  
  const activeBtn = document.querySelector(`button[onclick="switchTab('${tabId}', '${tabName}')"]`);
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
      showToast("Đăng nhập thành công", "success");
    } else {
      loginError.textContent = "Bạn không có quyền quản trị viên.";
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
    showToast("Không thể tải dữ liệu Dashboard.", "danger");
  }
}

// --- Book Management Actions ---
function renderBooksList(books) {
  booksListBody.innerHTML = "";
  if (books.length === 0) {
    booksListBody.innerHTML = `<tr><td colspan="5" style="text-align: center; color: var(--text-muted); padding: 3rem 0;">Chưa có cuốn sách nào trong thư viện.</td></tr>`;
    return;
  }

  books.forEach(b => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td>
        <div class="cover-preview">
          ${b.cover ? `<img src="${b.cover}" alt="cover" />` : '<span style="color:var(--text-muted);font-size:0.65rem;">No Cover</span>'}
        </div>
      </td>
      <td>
        <div style="font-weight: 500; color: var(--text-main); font-size: 0.875rem;">${b.title}</div>
        <div style="font-size: 0.75rem; color: var(--text-muted); margin-top: 0.25rem;">Tác giả: ${b.author || 'Không rõ'}</div>
      </td>
      <td style="font-family: monospace; font-size: 0.8125rem; color: var(--text-muted);">${b.slug}</td>
      <td style="font-weight: 400; color: var(--text-muted);">${b.pageCount} trang</td>
      <td>
        <div style="display: flex; gap: 0.5rem; justify-content: flex-end;">
          <button class="btn btn-secondary btn-sm" onclick="downloadBook('${b.slug}')">Tải về (.bkb)</button>
          <button class="btn btn-danger btn-sm" onclick="deleteBook('${b.slug}', '${b.title}')">Xóa</button>
        </div>
      </td>
    `;
    booksListBody.appendChild(tr);
  });
}

window.downloadBook = function(slug) {
  const downloadUrl = `/api/books/${slug}/download?token=${encodeURIComponent(token)}`;
  window.location.href = downloadUrl;
};

window.deleteBook = async function(slug, title) {
  const confirmed = await showConfirm(`Cảnh báo: Bạn có chắc muốn xóa cuốn sách <strong>"${title}"</strong>?<br><br>File vật lý và tất cả highlight liên quan sẽ bị xóa vĩnh viễn khỏi hệ thống.`, "Xóa sách");
  if (!confirmed) return;
  
  try {
    await apiCall(`/api/books/${slug}`, "DELETE");
    showToast(`Đã xóa "${title}" thành công.`, "success");
    loadDashboardData();
  } catch (err) {
    showToast("Xóa sách thất bại: " + err.message, "danger");
  }
};

// Handle Drag-and-Drop and File Uploader
window.handleBkbUpload = function(file) {
  if (!file) return;
  if (!file.name.endsWith(".bkb")) {
    showToast("Định dạng file không hỗ trợ. Vui lòng chọn file .bkb", "danger");
    return;
  }

  progressContainer.style.display = "block";
  progressBar.style.width = "0%";
  uploadStatus.style.color = "var(--text-muted)";
  uploadStatus.textContent = "Đang bắt đầu tải lên...";

  const formData = new FormData();
  formData.append("file", file);

  const xhr = new XMLHttpRequest();
  xhr.open("POST", "/api/books/upload", true);
  
  if (token) {
    xhr.setRequestHeader("Authorization", `Bearer ${token}`);
  }

  xhr.upload.addEventListener("progress", (e) => {
    if (e.lengthComputable) {
      const percent = Math.round((e.loaded / e.total) * 100);
      progressBar.style.width = `${percent}%`;
      uploadStatus.textContent = `Tải lên: ${percent}%`;
    }
  });

  xhr.onload = () => {
    if (xhr.status === 200) {
      const res = JSON.parse(xhr.responseText);
      uploadStatus.style.color = "var(--success)";
      uploadStatus.textContent = "Hoàn tất tải lên!";
      showToast("Nạp sách thành công", "success");
      progressBar.style.width = "100%";
      setTimeout(() => {
        progressContainer.style.display = "none";
        uploadStatus.textContent = "";
      }, 3000);
      loadDashboardData();
    } else {
      let errDetail = "Lỗi hệ thống";
      try {
        const errJson = JSON.parse(xhr.responseText);
        errDetail = errJson.detail || errDetail;
      } catch(err) {}
      uploadStatus.style.color = "var(--danger)";
      uploadStatus.textContent = errDetail;
      showToast("Lỗi tải sách: " + errDetail, "danger");
    }
  };

  xhr.onerror = () => {
    uploadStatus.style.color = "var(--danger)";
    uploadStatus.textContent = "Mất kết nối với máy chủ.";
    showToast("Lỗi kết nối", "danger");
  };

  xhr.send(formData);
};

// Drag and drop zone events
const dropZone = document.getElementById("drop-zone");
if (dropZone) {
  ['dragenter', 'dragover'].forEach(eventName => {
    dropZone.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropZone.classList.add("dragover");
    }, false);
  });

  ['dragleave', 'drop'].forEach(eventName => {
    dropZone.addEventListener(eventName, (e) => {
      e.preventDefault();
      dropZone.classList.remove("dragover");
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
  const isHidden = userCreationBox.classList.toggle("hidden");
  btnCreateUserToggle.textContent = isHidden ? "Thêm Độc Giả" : "Đóng Form";
  createUserForm.reset();
});

btnCancelUser.addEventListener("click", () => {
  userCreationBox.classList.add("hidden");
  btnCreateUserToggle.textContent = "Thêm Độc Giả";
});

createUserForm.addEventListener("submit", async (e) => {
  e.preventDefault();
  const username = createUserForm.elements["new-username"].value.trim();
  const password = createUserForm.elements["new-password"].value.trim();

  try {
    await apiCall(`/api/auth/register?username=${encodeURIComponent(username)}&password=${encodeURIComponent(password)}`, "POST");
    showToast(`Đã tạo tài khoản "${username}" thành công.`, "success");
    userCreationBox.classList.add("hidden");
    btnCreateUserToggle.textContent = "Thêm Độc Giả";
    loadDashboardData();
  } catch (err) {
    showToast("Lỗi tạo tài khoản: " + err.message, "danger");
  }
});

function renderUsersDropdown(users) {
  selectUser.innerHTML = "";
  let count = 0;
  users.forEach(u => {
    if (!u.is_admin) {
      count++;
      const opt = document.createElement("option");
      opt.value = u.id;
      opt.textContent = u.username;
      selectUser.appendChild(opt);
    }
  });
  if (count === 0) {
    const opt = document.createElement("option");
    opt.textContent = "-- Chưa có độc giả nào --";
    selectUser.appendChild(opt);
  }
}

function renderBooksDropdown(books) {
  selectBook.innerHTML = "";
  if (books.length === 0) {
    const opt = document.createElement("option");
    opt.textContent = "-- Thư viện trống --";
    selectBook.appendChild(opt);
    return;
  }
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
  if (!userId || !bookSlug) return showToast("Vui lòng chọn thông tin hợp lệ", "warning");

  try {
    await apiCall(`/api/admin/permissions?user_id=${userId}&book_slug=${encodeURIComponent(bookSlug)}`, "POST");
    showToast("Cấp quyền thành công", "success");
    loadDashboardData();
  } catch (err) {
    showToast("Lỗi cấp quyền: " + err.message, "danger");
  }
});

function renderPermissionsTable(permissions) {
  permissionsListBody.innerHTML = "";
  if (permissions.length === 0) {
    permissionsListBody.innerHTML = `<tr><td colspan="3" style="text-align: center; color: var(--text-muted); padding: 2rem 0;">Chưa có quyền đọc nào được cấp phát.</td></tr>`;
    return;
  }

  permissions.forEach(p => {
    const user = usersList.find(u => u.id === p.user_id);
    const book = booksList.find(b => b.slug === p.book_slug);
    const username = user ? user.username : `User ID ${p.user_id}`;
    const bookTitle = book ? book.title : p.book_slug;

    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td style="font-weight: 500; color: var(--text-main);">${username}</td>
      <td>${bookTitle}</td>
      <td>
        <div style="text-align: right;">
          <button class="btn btn-outline-danger btn-sm" onclick="revokePermission(${p.id})">Thu hồi</button>
        </div>
      </td>
    `;
    permissionsListBody.appendChild(tr);
  });
}

window.revokePermission = async function(id) {
  const confirmed = await showConfirm("Xác nhận thu hồi quyền truy cập này?", "Thu hồi quyền");
  if (!confirmed) return;
  try {
    await apiCall(`/api/admin/permissions/${id}`, "DELETE");
    showToast("Thu hồi quyền thành công", "success");
    loadDashboardData();
  } catch (err) {
    showToast("Lỗi thu hồi quyền: " + err.message, "danger");
  }
};

// --- API Keys Management Actions ---
btnCreateApiKey.addEventListener("click", () => {
  const isHidden = apikeyCreationBox.classList.toggle("hidden");
  btnCreateApiKey.textContent = isHidden ? "Tạo API Key" : "Hủy thao tác";
  newKeyDisplay.classList.add("hidden");
  apikeyNameInput.value = "";
});

btnCancelApiKey.addEventListener("click", () => {
  apikeyCreationBox.classList.add("hidden");
  btnCreateApiKey.textContent = "Tạo API Key";
});

btnSubmitApiKey.addEventListener("click", async () => {
  const name = apikeyNameInput.value.trim();
  if (!name) return showToast("Vui lòng nhập tên nhận diện cho Key", "warning");

  try {
    const res = await apiCall(`/api/admin/apikeys?name=${encodeURIComponent(name)}`, "POST");
    newKeyValue.textContent = res.key_value;
    newKeyDisplay.classList.remove("hidden");
    showToast("Đã khởi tạo API Key mới", "success");
    
    const apikeys = await apiCall("/api/admin/apikeys");
    renderApiKeysTable(apikeys);
  } catch (err) {
    showToast("Tạo API Key thất bại: " + err.message, "danger");
  }
});

function renderApiKeysTable(apikeys) {
  apikeysListBody.innerHTML = "";
  if (apikeys.length === 0) {
    apikeysListBody.innerHTML = `<tr><td colspan="4" style="text-align: center; color: var(--text-muted); padding: 2rem 0;">Chưa có API Key nào trong hệ thống.</td></tr>`;
    return;
  }

  apikeys.forEach(k => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td style="font-weight: 500; color: var(--text-main);">${k.name}</td>
      <td style="font-family: monospace; color: var(--text-muted);">${k.key_value.slice(0, 15)}...</td>
      <td>
        <span class="badge ${k.is_active ? 'badge-success' : 'badge-danger'}">
          ${k.is_active ? 'Hoạt động' : 'Đã thu hồi'}
        </span>
      </td>
      <td>
        <div style="text-align: right;">
          ${k.is_active ? `<button class="btn btn-outline-danger btn-sm" onclick="revokeKey(${k.id})">Vô hiệu hóa</button>` : '<span style="color:var(--text-muted);font-size:0.75rem;">—</span>'}
        </div>
      </td>
    `;
    apikeysListBody.appendChild(tr);
  });
}

window.revokeKey = async function(id) {
  const confirmed = await showConfirm("Xác nhận vô hiệu hóa API Key này? Mọi tác vụ dùng key này sẽ thất bại lập tức.", "Vô hiệu hóa Key");
  if (!confirmed) return;
  try {
    await apiCall(`/api/admin/apikeys/${id}`, "DELETE");
    showToast("API Key đã bị vô hiệu hóa", "success");
    loadDashboardData();
  } catch (err) {
    showToast("Lỗi vô hiệu hóa Key: " + err.message, "danger");
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
