// geohash-globe.js - Geohash channels and 3D globe explorer
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    showGeohashExplorer() {
        const modal = document.getElementById('geohashExplorerModal');
        if (modal) {
            modal.style.display = 'flex';

            // Wait for modal to be visible before initializing globe
            setTimeout(() => {
                // Check if canvas container exists
                const canvasContainer = document.getElementById('geohashGlobeCanvas');
                if (!canvasContainer || !canvasContainer.parentElement) {
                    return;
                }

                // Always reinitialize globe when opening
                this.initializeGlobe();
            }, 100);
        }
    },

    closeGeohashExplorer() {
        const modal = document.getElementById('geohashExplorerModal');
        if (modal) {
            modal.style.display = 'none';
        }

        // Stop animation
        this.globeAnimationActive = false;

        // Clean up globe resources
        if (this.globe) {
            // Dispose of renderer
            if (this.globe.renderer) {
                this.globe.renderer.dispose();
                this.globe.renderer.forceContextLoss();
                this.globe.renderer.domElement = null;
            }

            // Clean up scene
            if (this.globe.scene) {
                this.globe.scene.traverse((object) => {
                    if (object.geometry) {
                        object.geometry.dispose();
                    }
                    if (object.material) {
                        if (Array.isArray(object.material)) {
                            object.material.forEach(material => material.dispose());
                        } else {
                            object.material.dispose();
                        }
                    }
                });
            }

            this.globe = null;
        }

        // Clean up resize handler
        if (this.globeResizeHandler) {
            window.removeEventListener('resize', this.globeResizeHandler);
            this.globeResizeHandler = null;
        }

    },

    initializeGlobe() {
        const container = document.getElementById('geohashGlobeCanvas');

        if (!container) {
            return;
        }

        // Clear any existing content
        container.innerHTML = '';

        // Create globe viz container
        const globeViz = document.createElement('div');
        globeViz.id = 'globeViz';
        globeViz.style.width = '100%';
        globeViz.style.height = '100%';
        globeViz.style.position = 'absolute';
        globeViz.style.top = '0';
        globeViz.style.left = '0';
        container.appendChild(globeViz);

        // Determine if we should show "Your Location" in legend
        const showYourLocation = this.settings.sortByProximity && this.userLocation;

        // Re-add the controls and info panel HTML with conditional legend
        container.insertAdjacentHTML('beforeend', `
<div class="geohash-info-panel" id="geohashInfoPanel" style="display: none;">
    <div class="geohash-info-title" id="geohashInfoTitle">Channel Info</div>
    <div id="geohashInfoContent"></div>
    <button class="geohash-join-btn" id="geohashJoinBtn">Join Channel</button>
</div>

<div class="geohash-controls">
    <button class="geohash-control-btn" onclick="nym.resetGlobeView()">Reset View</button>
</div>

<div class="geohash-legend">
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot" style="background: var(--primary); box-shadow: 0 0 5px var(--primary);"></div>
        <span>Active Channels</span>
    </div>
    ${showYourLocation ? `
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot" style="background: var(--warning);"></div>
        <span>Your Location</span>
    </div>
    ` : ''}
</div>
`);

        // Get geohash channels
        this.updateGeohashChannels();

        // Calculate optimal distance based on screen size
        const isMobile = window.innerWidth <= 768;
        const initialDistance = isMobile ? 400 : 300;

        // Create globe with dynamic sizing
        const isPerf = this.performanceMode;
        const Globe = new ThreeGlobe()
            .globeImageUrl('https://unpkg.com/three-globe@2.31.0/example/img/earth-blue-marble.jpg');
        if (!isPerf) {
            Globe.bumpImageUrl('https://unpkg.com/three-globe@2.31.0/example/img/earth-topology.png');
        }

        // Setup renderer - disable antialias and limit pixel ratio in performance mode
        const renderer = new THREE.WebGLRenderer({ antialias: !isPerf, alpha: true });
        renderer.setPixelRatio(isPerf ? 1 : window.devicePixelRatio);
        globeViz.appendChild(renderer.domElement);

        // Setup camera
        const camera = new THREE.PerspectiveCamera();
        camera.position.z = initialDistance;

        // Define updateSize function
        const updateSize = () => {
            const width = container.clientWidth;
            const height = container.clientHeight;
            renderer.setSize(width, height);
            camera.aspect = width / height;
            camera.updateProjectionMatrix();
        };

        updateSize();

        // Setup scene with brighter lighting (fewer lights in performance mode)
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0x000011);
        scene.add(Globe);
        scene.add(new THREE.AmbientLight(0xffffff, isPerf ? 2.0 : 1.5));

        if (!isPerf) {
            const directionalLight1 = new THREE.DirectionalLight(0xffffff, 1.2);
            directionalLight1.position.set(5, 3, 5);
            scene.add(directionalLight1);

            const directionalLight2 = new THREE.DirectionalLight(0xffffff, 0.8);
            directionalLight2.position.set(-5, -3, -5);
            scene.add(directionalLight2);
        }

        // Create a container group for points that will rotate with the globe
        const pointsGroup = new THREE.Group();
        scene.add(pointsGroup);

        const GLOBE_RADIUS = 100; // three-globe default radius

        const polar2Cartesian = (lat, lng, relAltitude = 0) => {
            const phi = (90 - lat) * Math.PI / 180;
            const theta = (lng - 90) * Math.PI / 180;  // Subtract 90 instead of add
            const r = GLOBE_RADIUS * (1 + relAltitude);

            return {
                x: r * Math.sin(phi) * Math.cos(theta),
                y: r * Math.cos(phi),
                z: -r * Math.sin(phi) * Math.sin(theta)  // Negate the Z
            };
        };

        // Create clickable point meshes
        const pointMeshes = [];
        const POINT_ALTITUDE = 0.01; // Just above surface

        // Create individual sphere meshes for each geohash channel
        const sphereDetail = isPerf ? 6 : 16;
        this.geohashChannels.forEach((channel, index) => {
            const geometry = new THREE.SphereGeometry(2.5, sphereDetail, sphereDetail);
            const material = new THREE.MeshBasicMaterial({
                color: channel.isJoined ? 0x00ff00 : 0x00ffff,
                transparent: true,
                opacity: 0.9
            });
            const sphere = new THREE.Mesh(geometry, material);

            // Convert lat/lng to 3D position using three-globe's coordinate system
            const pos = polar2Cartesian(channel.lat, channel.lng, POINT_ALTITUDE);
            sphere.position.set(pos.x, pos.y, pos.z);


            // Store channel data on the mesh
            sphere.userData = {
                geohash: channel.geohash,
                lat: channel.lat,
                lng: channel.lng,
                channelIndex: index,
                isGeohashPoint: true
            };

            // Add to points group (not Globe) so we can control rotation separately
            pointsGroup.add(sphere);
            pointMeshes.push(sphere);
        });

        // Add user location if available (check both userLocation and proximity setting)
        const hasLocation = this.userLocation || (this.settings.sortByProximity && navigator.geolocation);

        if (this.userLocation) {
            const geometry = new THREE.SphereGeometry(3, sphereDetail, sphereDetail);
            const material = new THREE.MeshBasicMaterial({
                color: 0xffff00,
                transparent: true,
                opacity: 0.9
            });
            const sphere = new THREE.Mesh(geometry, material);

            const pos = polar2Cartesian(this.userLocation.lat, this.userLocation.lng, POINT_ALTITUDE);
            sphere.position.set(pos.x, pos.y, pos.z);

            sphere.userData = {
                isUserLocation: true
            };

            pointsGroup.add(sphere);

        } else if (this.settings.sortByProximity && navigator.geolocation) {
            // If proximity sorting is enabled but location not yet loaded, try to get it now
            navigator.geolocation.getCurrentPosition(
                (position) => {
                    this.userLocation = {
                        lat: position.coords.latitude,
                        lng: position.coords.longitude
                    };

                    // Add the yellow dot now that we have location
                    const geometry = new THREE.SphereGeometry(3, 16, 16);
                    const material = new THREE.MeshBasicMaterial({
                        color: 0xffff00,
                        transparent: true,
                        opacity: 0.9
                    });
                    const sphere = new THREE.Mesh(geometry, material);

                    const pos = polar2Cartesian(this.userLocation.lat, this.userLocation.lng, POINT_ALTITUDE);
                    sphere.position.set(pos.x, pos.y, pos.z);

                    sphere.userData = {
                        isUserLocation: true
                    };

                    pointsGroup.add(sphere);

                },
                (error) => {
                }
            );
        }

        // Interaction state
        let autoRotate = true;
        let mouseDownX = 0;
        let mouseDownY = 0;
        let mouseDownTime = 0;
        let totalDragDistance = 0;
        let isDragging = false;
        let hoveredMesh = null;
        const CLICK_THRESHOLD = 5;
        const CLICK_TIME_THRESHOLD = 300;

        // Raycaster for interaction detection
        const raycaster = new THREE.Raycaster();
        const mouse = new THREE.Vector2();

        renderer.domElement.style.cursor = 'grab';

        // Helper function to get mouse coordinates
        const getMouseCoordinates = (clientX, clientY) => {
            const rect = renderer.domElement.getBoundingClientRect();
            mouse.x = ((clientX - rect.left) / rect.width) * 2 - 1;
            mouse.y = -((clientY - rect.top) / rect.height) * 2 + 1;
        };

        // Hover detection
        const checkHover = (clientX, clientY) => {
            if (isDragging) return;

            getMouseCoordinates(clientX, clientY);
            raycaster.setFromCamera(mouse, camera);

            const intersects = raycaster.intersectObjects(pointMeshes, false);

            if (intersects.length > 0) {
                const intersectedMesh = intersects[0].object;

                if (intersectedMesh.userData.isGeohashPoint) {
                    hoveredMesh = intersectedMesh;
                    renderer.domElement.style.cursor = 'pointer';
                    intersectedMesh.scale.set(1.2, 1.2, 1.2);
                }
            } else {
                if (hoveredMesh && hoveredMesh.userData.isGeohashPoint) {
                    hoveredMesh.scale.set(1, 1, 1);
                }
                hoveredMesh = null;
                renderer.domElement.style.cursor = 'grab';
            }
        };

        // Mousemove for hover (RAF-throttled to one check per frame)
        let pendingHoverEvent = null;
        let hoverRafScheduled = false;
        renderer.domElement.addEventListener('mousemove', (e) => {
            if (isDragging) return;
            pendingHoverEvent = { clientX: e.clientX, clientY: e.clientY };
            if (hoverRafScheduled) return;
            hoverRafScheduled = true;
            requestAnimationFrame(() => {
                hoverRafScheduled = false;
                if (pendingHoverEvent) {
                    checkHover(pendingHoverEvent.clientX, pendingHoverEvent.clientY);
                    pendingHoverEvent = null;
                }
            });
        }, { passive: true });

        // Pointer down - start tracking
        renderer.domElement.addEventListener('pointerdown', (e) => {
            e.preventDefault();

            mouseDownX = e.clientX;
            mouseDownY = e.clientY;
            mouseDownTime = Date.now();
            totalDragDistance = 0;
            isDragging = false;
            autoRotate = false;
            renderer.domElement.style.cursor = 'grabbing';

            const onPointerMove = (moveEvent) => {
                const deltaX = moveEvent.clientX - mouseDownX;
                const deltaY = moveEvent.clientY - mouseDownY;

                totalDragDistance += Math.abs(deltaX) + Math.abs(deltaY);

                if (totalDragDistance > CLICK_THRESHOLD) {
                    isDragging = true;
                    if (hoveredMesh && hoveredMesh.userData.isGeohashPoint) {
                        hoveredMesh.scale.set(1, 1, 1);
                    }
                    hoveredMesh = null;
                }

                // Apply rotation to both globe AND points group
                const rotationDeltaX = deltaX * 0.005;
                const rotationDeltaY = deltaY * 0.005;

                Globe.rotation.y += rotationDeltaX;
                Globe.rotation.x += rotationDeltaY;
                Globe.rotation.x = Math.max(-Math.PI / 2, Math.min(Math.PI / 2, Globe.rotation.x));

                // Sync points group rotation with Globe
                pointsGroup.rotation.copy(Globe.rotation);

                mouseDownX = moveEvent.clientX;
                mouseDownY = moveEvent.clientY;
            };

            const onPointerUp = (upEvent) => {
                document.removeEventListener('pointermove', onPointerMove);
                document.removeEventListener('pointerup', onPointerUp);

                const clickDuration = Date.now() - mouseDownTime;
                renderer.domElement.style.cursor = 'grab';

                // Check if this was a click
                if (totalDragDistance <= CLICK_THRESHOLD && clickDuration <= CLICK_TIME_THRESHOLD) {
                    getMouseCoordinates(upEvent.clientX, upEvent.clientY);
                    raycaster.setFromCamera(mouse, camera);

                    const intersects = raycaster.intersectObjects(pointMeshes, false);

                    if (intersects.length > 0) {
                        const clickedMesh = intersects[0].object;

                        if (clickedMesh.userData.isGeohashPoint) {
                            const geohash = clickedMesh.userData.geohash;
                            const clickedChannel = this.geohashChannels.find(ch => ch.geohash === geohash);

                            if (clickedChannel) {
                                this.selectGeohashChannel(clickedChannel);
                            }
                        }
                    }
                }

                isDragging = false;
                setTimeout(() => checkHover(upEvent.clientX, upEvent.clientY), 50);
            };

            document.addEventListener('pointermove', onPointerMove);
            document.addEventListener('pointerup', onPointerUp);
        });

        // Wheel zoom (passive: false so we can preventDefault page scroll)
        renderer.domElement.addEventListener('wheel', (e) => {
            e.preventDefault();
            camera.position.z += e.deltaY * 0.2;
            camera.position.z = Math.max(150, Math.min(600, camera.position.z));
        }, { passive: false });

        // Pinch-to-zoom support for mobile
        let touchDistance = 0;
        let initialCameraZ = camera.position.z;

        renderer.domElement.addEventListener('touchstart', (e) => {
            if (e.touches.length === 2) {
                // Two-finger touch - start pinch
                const dx = e.touches[0].clientX - e.touches[1].clientX;
                const dy = e.touches[0].clientY - e.touches[1].clientY;
                touchDistance = Math.sqrt(dx * dx + dy * dy);
                initialCameraZ = camera.position.z;

                // Stop auto-rotation during pinch
                autoRotate = false;
            }
        }, { passive: false });

        renderer.domElement.addEventListener('touchmove', (e) => {
            if (e.touches.length === 2) {
                e.preventDefault();

                // Calculate new distance between touches
                const dx = e.touches[0].clientX - e.touches[1].clientX;
                const dy = e.touches[0].clientY - e.touches[1].clientY;
                const newDistance = Math.sqrt(dx * dx + dy * dy);

                if (touchDistance > 0) {
                    // Calculate zoom factor based on pinch distance change
                    const scale = touchDistance / newDistance;
                    const newZ = initialCameraZ * scale;

                    // Apply zoom with limits
                    camera.position.z = Math.max(150, Math.min(600, newZ));
                }
            }
        }, { passive: false });

        renderer.domElement.addEventListener('touchend', (e) => {
            if (e.touches.length < 2) {
                // Reset pinch state when less than 2 fingers
                touchDistance = 0;
            }
        }, { passive: true });

        // Animation loop (throttled to ~20fps in performance mode)
        let lastFrame = 0;
        const frameInterval = isPerf ? 50 : 0; // 50ms = ~20fps
        const animate = (now) => {
            if (!this.globeAnimationActive) return;

            if (isPerf && now - lastFrame < frameInterval) {
                requestAnimationFrame(animate);
                return;
            }
            lastFrame = now;

            if (autoRotate) {
                Globe.rotation.y += 0.002;
                // Sync points group rotation with Globe during auto-rotation
                pointsGroup.rotation.copy(Globe.rotation);
            }

            renderer.render(scene, camera);
            requestAnimationFrame(animate);
        };

        // Store references
        this.globe = {
            scene: Globe,
            camera: camera,
            renderer: renderer,
            animate: animate,
            pointMeshes: pointMeshes,
            pointsGroup: pointsGroup,
            autoRotate: autoRotate,
            setAutoRotate: (value) => {
                autoRotate = value;
                this.globe.autoRotate = value;
            },
            updatePoints: () => {
                this.updateGeohashChannels();

                // Remove existing point meshes from points group
                pointMeshes.forEach(mesh => pointsGroup.remove(mesh));
                pointMeshes.length = 0;

                // Recreate point meshes
                const sd = this.performanceMode ? 6 : 16;
                this.geohashChannels.forEach((channel, index) => {
                    const geometry = new THREE.SphereGeometry(2.5, sd, sd);
                    const material = new THREE.MeshBasicMaterial({
                        color: channel.isJoined ? 0x00ff00 : 0x00ffff,
                        transparent: true,
                        opacity: 0.9
                    });
                    const sphere = new THREE.Mesh(geometry, material);

                    const pos = polar2Cartesian(channel.lat, channel.lng, POINT_ALTITUDE);
                    sphere.position.set(pos.x, pos.y, pos.z);

                    sphere.userData = {
                        geohash: channel.geohash,
                        lat: channel.lat,
                        lng: channel.lng,
                        channelIndex: index,
                        isGeohashPoint: true
                    };

                    pointsGroup.add(sphere);
                    pointMeshes.push(sphere);
                });

                // Re-add user location if available
                if (this.userLocation) {
                    const geometry = new THREE.SphereGeometry(3, sd, sd);
                    const material = new THREE.MeshBasicMaterial({
                        color: 0xffff00,
                        transparent: true,
                        opacity: 0.9
                    });
                    const sphere = new THREE.Mesh(geometry, material);

                    const pos = polar2Cartesian(this.userLocation.lat, this.userLocation.lng, POINT_ALTITUDE);
                    sphere.position.set(pos.x, pos.y, pos.z);

                    sphere.userData = {
                        isUserLocation: true
                    };

                    pointsGroup.add(sphere);
                }

                // Sync rotation after updating points
                pointsGroup.rotation.copy(Globe.rotation);
            }
        };

        this.globeAnimationActive = true;

        // Handle resize (debounced 150ms to avoid thrashing during window drag)
        let resizeDebounceTimer = null;
        const handleResize = () => {
            if (resizeDebounceTimer) clearTimeout(resizeDebounceTimer);
            resizeDebounceTimer = setTimeout(() => {
                resizeDebounceTimer = null;
                updateSize();
            }, 150);
        };

        if (this.globeResizeHandler) {
            window.removeEventListener('resize', this.globeResizeHandler);
        }
        this.globeResizeHandler = handleResize;
        window.addEventListener('resize', this.globeResizeHandler, { passive: true });

        // Start animation
        animate();

    },

    joinSelectedGeohash() {
        if (this.selectedGeohash) {
            const geohash = this.selectedGeohash.toLowerCase();


            // Close the explorer modal
            this.closeGeohashExplorer();

            // Small delay to ensure modal closes before switching
            setTimeout(() => {
                // Add the channel if not already present
                if (!this.channels.has(geohash)) {
                    this.addChannel(geohash, geohash);
                }

                // Switch to the channel
                this.switchChannel(geohash, geohash);

                // Mark as user-joined
                this.userJoinedChannels.add(geohash);
                this.saveUserChannels();
                this._debouncedNostrSettingsSave();

                this.displaySystemMessage(`Joined geohash channel #${geohash}`);
            }, 100);
        }
    },

    resetGlobeView() {
        if (this.globe) {
            this.globe.camera.position.set(0, 0, 300);
            this.globe.scene.rotation.set(0, 0, 0);
            this.globe.setAutoRotate(true);
            this.globe.autoRotate = true;

            // Close any open geohash channel details
            const infoPanel = document.getElementById('geohashInfoPanel');
            if (infoPanel) {
                infoPanel.style.display = 'none';
            }

        }
    },

    decodeGeohash(geohash) {
        const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
        const bounds = {
            lat: [-90, 90],
            lng: [-180, 180]
        };

        let isEven = true;
        for (let i = 0; i < geohash.length; i++) {
            const cd = BASE32.indexOf(geohash[i].toLowerCase());
            if (cd === -1) throw new Error('Invalid geohash character');

            for (let j = 4; j >= 0; j--) {
                const mask = 1 << j;
                if (isEven) {
                    bounds.lng = (cd & mask) ?
                        [(bounds.lng[0] + bounds.lng[1]) / 2, bounds.lng[1]] :
                        [bounds.lng[0], (bounds.lng[0] + bounds.lng[1]) / 2];
                } else {
                    bounds.lat = (cd & mask) ?
                        [(bounds.lat[0] + bounds.lat[1]) / 2, bounds.lat[1]] :
                        [bounds.lat[0], (bounds.lat[0] + bounds.lat[1]) / 2];
                }
                isEven = !isEven;
            }
        }

        return {
            lat: (bounds.lat[0] + bounds.lat[1]) / 2,
            lng: (bounds.lng[0] + bounds.lng[1]) / 2
        };
    },

    getGeohashLocation(geohash) {
        try {
            const coords = this.decodeGeohash(geohash);
            const lat = coords.lat;
            const lng = coords.lng;

            // Format coordinates properly with N/S and E/W
            const latStr = Math.abs(lat).toFixed(2) + '°' + (lat >= 0 ? 'N' : 'S');
            const lngStr = Math.abs(lng).toFixed(2) + '°' + (lng >= 0 ? 'E' : 'W');

            return `${latStr}, ${lngStr}`;
        } catch (e) {
            return '';
        }
    },

    calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371; // Earth radius in km
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    },

});
