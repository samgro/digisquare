//
//  CreatePlaceView.swift
//  Hackysack
//

import CoreLocation
import MapKit
import SwiftUI

/// Adds a venue the place data does not have: a name, a category, an
/// address, and a pin dropped on a map. The pin starts at the user's
/// location and moves wherever they tap. Saving posts to `POST /places` and
/// hands the created place back so the caller can check in there.
struct CreatePlaceView: View {
    @Environment(LocationManager.self) private var locationManager

    /// What the user had typed into the search box, if anything: the most
    /// likely name for the place they could not find.
    var initialName = ""
    let onCreated: (Place) -> Void

    @State private var name: String
    @State private var category: PlaceCategory?
    /// On by default: a home or an office should not be published to
    /// strangers by accident. Friends can still find a private place.
    @State private var isPrivate = true
    @State private var street = ""
    @State private var locality = ""
    @State private var region = ""
    @State private var postcode = ""
    @State private var country = Locale.current.region?.identifier ?? ""
    @State private var website = ""
    @State private var phone = ""
    @State private var pinCoordinate: CLLocationCoordinate2D?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let placesAPI = PlacesAPI()

    /// How much map to show around the pin, in meters.
    private static let mapSpan = 400.0

    init(initialName: String = "", onCreated: @escaping (Place) -> Void) {
        self.initialName = initialName
        self.onCreated = onCreated
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                Picker("Category", selection: $category) {
                    Text("None").tag(PlaceCategory?.none)
                    ForEach(PlaceCategory.all) { category in
                        Text(category.displayName).tag(Optional(category))
                    }
                }
                Toggle("Private", isOn: $isPrivate)
            } header: {
                Text("Place")
            } footer: {
                Text(isPrivate
                     ? "Only you and your friends can find a private place. Your checkins there still show up for friends."
                     : "Anyone can find a public place.")
            }

            Section {
                mapPicker
                    .listRowInsets(EdgeInsets())
                if let location = locationManager.location {
                    Button {
                        movePin(to: location.coordinate)
                    } label: {
                        Label("Use My Location", systemImage: "location.fill")
                    }
                }
            } header: {
                Text("Pin")
            } footer: {
                Text(pinCoordinate == nil
                     ? "Tap the map to drop a pin where the place is."
                     : "Tap the map to move the pin.")
            }

            Section("Address") {
                TextField("Street", text: $street)
                    .textContentType(.streetAddressLine1)
                TextField("City", text: $locality)
                    .textContentType(.addressCity)
                TextField("State or region", text: $region)
                    .textContentType(.addressState)
                TextField("Postal code", text: $postcode)
                    .textContentType(.postalCode)
                TextField("Country code (two letters)", text: $country)
                    .textContentType(.countryName)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }

            Section("Details") {
                TextField("Website", text: $website)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Phone", text: $phone)
                    .textContentType(.telephoneNumber)
                    .keyboardType(.phonePad)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Add a Place")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .disabled(isSaving)
        .alert("Couldn't Save Place", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            if pinCoordinate == nil, let location = locationManager.location {
                movePin(to: location.coordinate)
            }
        }
    }

    private var mapPicker: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                UserAnnotation()
                if let pinCoordinate {
                    Marker(trimmedName.isEmpty ? "New Place" : trimmedName, coordinate: pinCoordinate)
                        .tint(.orange)
                }
            }
            .mapControls {
                MapUserLocationButton()
            }
            .onTapGesture(coordinateSpace: .local) { screenPoint in
                if let coordinate = proxy.convert(screenPoint, from: .local) {
                    // Only the pin moves; the camera stays where the user put it.
                    pinCoordinate = coordinate
                }
            }
        }
        .frame(height: 260)
        .accessibilityLabel("Map")
        .accessibilityHint("Tap to place the pin")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && pinCoordinate != nil
    }

    private func movePin(to coordinate: CLLocationCoordinate2D) {
        pinCoordinate = coordinate
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: Self.mapSpan,
                longitudinalMeters: Self.mapSpan
            )
        )
    }

    private func save() {
        guard let pinCoordinate, canSave else { return }
        let draft = PlaceDraft(
            name: trimmedName,
            primaryType: category?.code,
            isPrivate: isPrivate,
            street: street,
            locality: locality,
            region: region,
            postcode: postcode,
            country: country,
            latitude: pinCoordinate.latitude,
            longitude: pinCoordinate.longitude,
            website: website,
            phone: phone
        )
        isSaving = true
        Task {
            do {
                let place = try await placesAPI.createPlace(draft)
                isSaving = false
                onCreated(place)
            } catch {
                isSaving = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        CreatePlaceView(initialName: "Sam's Garage") { place in
            print("Created \(place.name)")
        }
    }
    .environment({
        let locationManager = LocationManager()
        locationManager.location = CLLocation(latitude: 37.7749, longitude: -122.4194)
        return locationManager
    }())
}
